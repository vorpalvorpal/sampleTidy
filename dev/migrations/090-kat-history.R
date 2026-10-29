# Operator-run migration: import the historical results of the OTHER Katoomba WMF
# monitoring points (groundwater bores 8/10A/11B/12, LB12/DP1, leachate, surface
# waters S1A-S9 and effluent E1) from ACIRL's whole-site PDF reports of Aug 2015 -
# May 2020, which no package adapter reads. Marker 1090. Requires 1089.
# Authority: Robin, 2026-10-29 (approved importing the other Katoomba points'
# history from the same ACIRL reports as 089).
#
# ---- WHY -----------------------------------------------------------------------
# Katoomba's LMF is calibrated per sample against the groundwater reference bore
# K.MW08 over the trailing five years. K.MW08 had nothing in the database before
# Aug 2020, so the MP bore history imported by 089 got no LMF before Dec 2022.
# These reports carry K.MW08 ("BORE 8"), the other bores, the receptors and the
# leachate for the same rounds.
#
# ---- POINT IDENTITY (one mapping table, .mig090_points) --------------------------
# Every printed site name maps to an existing feature. Evidence:
#   * ACIRL 24006990-08 (Aug 2020), the same report series, is in the database from
#     its workbook and ALS ES2028249: its 11 Aug 2020 "BORE 8" column equals the
#     stored K.MW08 values cell by cell (118 of 119 compared cells; the one miss is
#     the second, BTEXN "Naphthalene" row), and likewise BORE10A = K.MW10A, BORE11B
#     = K.MW11B, BORE12 = K.MW12, LEACHATE = K.L01 (115/116), S1A/S3/S5-S9 =
#     K.S01A/K.S03/K.S05-K.S09.
#   * The EPL 10034 sampling-site table (Aug 2013) gives GW8 = "Ground Water Bore
#     8" at MGA56 251513.3 / 6268090.7, which is K.MW08's stored position to the
#     decimetre; GW10A, GW11B, BH12, DP1, SW1A, S3, S5 and E1 equal K.MW10A,
#     K.MW11B, K.MW12, K.MW05, K.S01A, K.S03, K.S05 and K.E01 the same way.
#   * LB12 / "LB12/DP1" -> K.MW05: the reports print "LB12/DP1"; K.MW05's own
#     comment is "Referred to as DP1 in EPL", and DP1's EPL position is K.MW05's.
#   * "Effluent Water" (2015-16) and "E1 - Effluent 1" (Aug 2016) -> K.E01 (EPL
#     E1 "Effluent"), "E2 - Effluent 2" (Aug 2016) -> K.E02. They print only "Not
#     Discharging" / "No Discharge", so they add at most a Flow observation
#     sample ("No discharge"; "Not Discharging" splits to nothing and makes no
#     sample). The "Other Site Name" rows (S5 = E1, S6 = E2) are annotations only:
#     S5 and S6 stay K.S05 / K.S06, exactly as the Aug 2020 report was imported.
#   * BORE 8 = K.MW08 is also continuous in the data: pH 4.2-5.7 and EC 57-92
#     uS/cm in 2015-20, as K.MW08 reads from Aug 2020 on.
#   * LEACHATE -> K.L01 follows the Aug 2020 import; the 2013 EPL "LE1" position
#     is about 45 m from K.L01's (the leachate dam was rebuilt 2015-17).
#
# ---- WHAT THIS IMPORTS, AND HOW ----------------------------------------------------
# 17 PDF reports: the 16 whole-site reports 089 already holds (089 imported only
# their MP columns) and the Nov 2016 quarterly (24005840-01), whose MP columns
# carry no result (one merged "Annual Parameters Analysed" cell), so 089 left it out. The tables were transcribed into the frozen
# 090-kat-history-INPUT-values.csv: one row per printed non-MP cell, value as
# printed. Ten reports have a text layer (pdftotext -bbox, each word assigned to
# the nearest site-column centre; the same parser reproduces 089's MP cells of
# those reports exactly). Seven are scanned: each was read twice, independently,
# from 300 dpi page images; the two readings agree on all 5,563 cells, and both
# reproduce 089's adjudicated MP cells of those pages exactly (INPUT-files `note`).
# Surrogate (%) rows and the "Other Site Name" row are not transcribed.
#
# The import goes through ingest_dir() exactly as 089 did: an OPERATOR adapter
# (`acirl_pdf_090`, defined here, registered for this run only) claims exactly the
# frozen PDFs by hash and returns the frozen rows in the ACIRL workbook adapter's
# IR shape (org ACIRL, work_order = report number, field rows + the observation
# split into Comments / Flow observation, the ALS analytes as ACIRL
# TRANSCRIPTIONS with method NULL, report$header$report_no and
# report$als_work_orders). Alias, analyte, unit and project handling, the sample
# identity and duplicate checks, archiving and ingest_file are the pipeline's own.
#
# The 16 PDFs 089 imported are `archived` in ingest_file, a terminal state the
# router never re-decides. Phase B0 therefore resets each of them to `seen` with
# ingest_file_set_state(reset = TRUE) - the router's own reset, as 040 did for the
# ES2623357 XTAB - writing the two field changes to change_log. archive_file()
# dedupes on hash, so each PDF keeps its 089 asset; the report project and its ALS
# child (made by 089) are found again, not duplicated; the re-ingest guard does
# not fire because the only asset under each report project is the file itself.
# Afterwards ingest_file.adapter of those 16 reads acirl_pdf_090; their assets and
# 089's MP samples are unchanged.
#
# Scope rules (Robin): only values NOT already in the database. The CHECK and the
# run refuse if any planned point already has a sample on a planned day, or if any
# cited ALS work order already holds ALS results (the originals would make these
# transcriptions duplicates); 090-kat-history-DISCREPANCIES.csv lists any report
# cell that disagrees with a stored value (none at the time of writing). Below-LOR
# cells stay censored ("<x"). MP columns are not touched (089). Landfill-gas and
# building-gas pages are not imported. A row label printed twice in one column
# (the BTEXN "Naphthalene" after the PAH one) keeps the first and skips the second.
# One sample per mapped point and day: a column headed "LB12/DP1" on one page and
# "LB12" on the next is one K.MW05 sample. INPUT-corrections holds the printed
# cells changed before parsing, each with its reason: a blank units cell filled
# (Phenols (Total), leachate column of the annual reports: mg/L as the same row
# prints for the bores) and a value withheld, never replaced (Mar 2017 S1A
# Temperature printed 166.9).
#
# ---- PHASES --------------------------------------------------------------------
# A (one transaction): the feature_alias arms the printed names need (INPUT-alias:
#   names whose key resolves to no feature on the sample days), bounded to the
#   history window so they never overlap an existing arm of another feature; and
#   date_start moved back on any mapped feature that starts after its first
#   imported day (none at the time of writing).
# B0 (one transaction): reset the 089-held PDFs' ingest_file rows to `seen`.
# B: ingest_dir() of a staging inbox holding exactly the frozen PDFs, adapter
#   registered, remove_ingested FALSE. Verified after: every PDF archived with
#   exactly one asset; new samples only at mapped features on frozen days; new
#   analyses = the adapter's emitted result rows; no existing sample changed.
# C (one transaction): an asset_filing row (system 'trim', adopted) for each PDF
#   whose asset has none - the Nov 2016 quarterly - read from the untracked
#   090-kat-history-TRIM.csv (record numbers are not in this public repo); then
#   marker 1090.
#
# Idempotent: marker present -> re-verify, no-op. A run stopped after A, B0 or B
# can be re-run: A skips arms already present, B0 resets only rows still archived
# by 089's adapter, B is a no-op for archived files, C's register_filing() is
# "unchanged".
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/090-kat-history.R", envir = env)
#   env$mig090_run(db = st_config("live_db"), snapshot_dir = ..., archive_dir = st_config("archive_dir"),
#                  work_dir = ..., files_dir = "dev/migrations/090-kat-history-FILES",
#                  trim_csv = "dev/migrations/090-kat-history-TRIM.csv", dry_run = TRUE)

.mig090_marker_version <- 1090L
.mig090_requires <- 1089L
.mig090_name <- "090-kat-history"
.mig090_actor <- .mig090_name
.mig090_adapter_id <- "acirl_pdf_090"
.mig090_adapter_version <- "1"
.mig090_prior_adapter <- "acirl_pdf_089"
.mig090_confirmed_by <- "R. Shannon"
.mig090_trim_system <- "trim"

# THE point mapping (one table): printed site name (matched on .rc_feature_key)
# -> feature. Change it here if the mapping is ever ruled otherwise.
.mig090_points <- utils::read.csv(text = 'printed,feature
BORE 8,K.MW08
BORE10A,K.MW10A
BORE11B,K.MW11B
BORE12,K.MW12
LB12,K.MW05
LB12/DP1,K.MW05
LEACHATE,K.L01
S1A,K.S01A
S3,K.S03
S5,K.S05
S6,K.S06
S7,K.S07
S8,K.S08
S9,K.S09
Effluent Water,K.E01
E1 - Effluent 1,K.E01
E2 - Effluent 2,K.E02', stringsAsFactors = FALSE, colClasses = "character")

# Printed row label -> analyte_raw: the ACIRL lab_method name (the field
# parameters are method 'field', the ALS suite are ACIRL transcriptions with
# method NULL; "C6 - C10 Fraction  minus BTEX (F1)" carries the registry's double
# space), "<obs>" for the observation row. Surrogate (%) rows are not in the
# INPUT. A label not listed aborts the run.
.mig090_labels <- utils::read.csv(text = 'printed,analyte_raw
General Comments/ Observations,<obs>
pH,pH
Electrical Conductivity,Electrical Conductivity
Total Suspended Solids,Total Suspended Solids
Total Dissolved Solids,Total Dissolved Solids
Hydroxide Alkalinity as CaCO3,Hydroxide Alkalinity as CaCO3
Carbonate Alkalinity as CaCO3,Carbonate Alkalinity as CaCO3
Bicarbonate Alkalinity as CaCO3,Bicarbonate Alkalinity as CaCO3
Total Alkalinity as CaCO3,Total Alkalinity as CaCO3
Sulfate as SO4 - Turbidimetric,Sulfate as SO4 - Turbidimetric
Chloride,Chloride
Calcium,Calcium
Magnesium,Magnesium
Sodium,Sodium
Potassium,Potassium
Aluminium,Aluminium
Arsenic,Arsenic
Barium,Barium
Cadmium,Cadmium
Chromium,Chromium
Cobalt,Cobalt
Copper,Copper
Lead,Lead
Manganese,Manganese
Zinc,Zinc
Mercury,Mercury
Hexavalent Chromium,Hexavalent Chromium
Fluoride,Fluoride
Ammonia as N,Ammonia as N
Nitrite as N,Nitrite as N
Nitrate as N,Nitrate as N
Nitrite + Nitrate as N,Nitrite + Nitrate as N
Total Phosphorus as P,Total Phosphorus as P
Total Organic Carbon,Total Organic Carbon
Chemical Oxygen Demand,Chemical Oxygen Demand
Biochemical Oxygen Demand,Biochemical Oxygen Demand
Phenols (Total),Phenols (Total)
alpha-BHC,alpha-BHC
Hexachlorobenzene (HCB),Hexachlorobenzene (HCB)
beta-BHC,beta-BHC
gamma-BHC,gamma-BHC
delta-BHC,delta-BHC
Heptachlor,Heptachlor
Aldrin,Aldrin
Heptachlor epoxide,Heptachlor epoxide
trans-Chlordane,trans-Chlordane
alpha-Endosulfan,alpha-Endosulfan
cis-Chlordane,cis-Chlordane
Dieldrin,Dieldrin
4.4`-DDE,4.4`-DDE
Endrin,Endrin
beta-Endosulfan,beta-Endosulfan
4.4`-DDD,4.4`-DDD
Endrin aldehyde,Endrin aldehyde
Endosulfan sulfate,Endosulfan sulfate
4.4`-DDT,4.4`-DDT
Endrin ketone,Endrin ketone
Methoxychlor,Methoxychlor
Total Chlordane (sum),Total Chlordane (sum)
Sum of DDD + DDE + DDT,Sum of DDD + DDE + DDT
Sum of Aldrin + Dieldrin,Sum of Aldrin + Dieldrin
Dichlorvos,Dichlorvos
Demeton-S-methyl,Demeton-S-methyl
Monocrotophos,Monocrotophos
Dimethoate,Dimethoate
Diazinon,Diazinon
Chlorpyrifos-methyl,Chlorpyrifos-methyl
Parathion-methyl,Parathion-methyl
Malathion,Malathion
Fenthion,Fenthion
Chlorpyrifos,Chlorpyrifos
Parathion,Parathion
Pirimphos-ethyl,Pirimphos-ethyl
Chlorfenvinphos,Chlorfenvinphos
Bromophos-ethyl,Bromophos-ethyl
Fenamiphos,Fenamiphos
Prothiofos,Prothiofos
Ethion,Ethion
Carbophenothion,Carbophenothion
Azinphos Methyl,Azinphos Methyl
Naphthalene,Naphthalene
Acenaphthylene,Acenaphthylene
Acenaphthene,Acenaphthene
Fluorene,Fluorene
Phenanthrene,Phenanthrene
Anthracene,Anthracene
Fluoranthene,Fluoranthene
Pyrene,Pyrene
Benz(a)anthracene,Benz(a)anthracene
Chrysene,Chrysene
Benzo(b+j)fluoranthene,Benzo(b+j)fluoranthene
Benzo(k)fluoranthene,Benzo(k)fluoranthene
Benzo(a)pyrene,Benzo(a)pyrene
Indeno(1.2.3.cd)pyrene,Indeno(1.2.3.cd)pyrene
Dibenz(a.h)anthracene,Dibenz(a.h)anthracene
Benzo(g.h.i)perylene,Benzo(g.h.i)perylene
Sum of polycyclic aromatic hydrocarbons,Sum of polycyclic aromatic hydrocarbons
Benzo(a)pyrene TEQ (zero),Benzo(a)pyrene TEQ (zero)
C6 - C9 Fraction,C6 - C9 Fraction
C10 - C14 Fraction,C10 - C14 Fraction
C15 - C28 Fraction,C15 - C28 Fraction
C29 - C36 Fraction,C29 - C36 Fraction
C10 - C36 Fraction (sum),C10 - C36 Fraction (sum)
C6 - C10 Fraction,C6 - C10 Fraction
C6 - C10 Fraction minus BTEX (F1),C6 - C10 Fraction  minus BTEX (F1)
>C10 - C16 Fraction,>C10 - C16 Fraction
>C16 - C34 Fraction,>C16 - C34 Fraction
>C34 - C40 Fraction,>C34 - C40 Fraction
>C10 - C40 Fraction (sum),>C10 - C40 Fraction (sum)
>C10 - C16 Fraction minus Naphthalene (F2),>C10 - C16 Fraction minus Naphthalene (F2)
Benzene,Benzene
Toluene,Toluene
Ethylbenzene,Ethylbenzene
meta- & para-Xylene,meta- & para-Xylene
ortho-Xylene,ortho-Xylene
Total Xylenes,Total Xylenes
Sum of BTEX,Sum of BTEX
Water Height,Water Height
Temperature,Temperature',
  stringsAsFactors = FALSE, colClasses = "character", na.strings = "NA_", encoding = "UTF-8")

.mig090_files_cols <- c("hash", "staged_name", "report_no", "als_work_order", "sample_days", "n_values", "note")
.mig090_values_cols <- c("hash", "source_ref", "feature_raw", "sample_datetime_raw", "label", "units_raw", "value_raw")
.mig090_alias_cols <- c("name", "feature", "date_start", "date_end")
.mig090_corr_cols <- c("hash", "feature_raw", "label", "field", "printed", "corrected", "reason")
.mig090_trim_cols <- c("hash", "trim_record", "trim_uri", "container", "title", "record_date")
.mig090_not_reported <- c("_", "-", "--", "---", "----", "-----", "")

.mig090_fail <- function(msg) cli::cli_abort(paste0(.mig090_name, ": ", msg), class = "sampletidy_error")
.mig090_scalar <- function(con, sql, ...) {
  as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
}
.mig090_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig090_syd <- function(col) sprintf("CAST((%s AT TIME ZONE 'UTC') AT TIME ZONE 'Australia/Sydney' AS DATE)", col)
.mig090_csv_path <- function(dir, what) file.path(dir, sprintf("%s-%s.csv", .mig090_name, what))
.mig090_read <- function(p, cols) {
  if (!file.exists(p)) .mig090_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), cols)) .mig090_fail(sprintf("%s: columns are not as planned.", basename(p)))
  x
}
.mig090_point_of <- function(feature_raw) {
  .mig090_points$feature[match(.rc_feature_key(feature_raw), .rc_feature_key(.mig090_points$printed))]
}

# ---- inputs ----------------------------------------------------------------------

mig090_read_inputs <- function(input_dir = "dev/migrations") {
  files <- .mig090_read(.mig090_csv_path(input_dir, "INPUT-files"), .mig090_files_cols)
  values <- .mig090_read(.mig090_csv_path(input_dir, "INPUT-values"), .mig090_values_cols)
  alias <- .mig090_read(.mig090_csv_path(input_dir, "INPUT-alias"), .mig090_alias_cols)
  corr <- .mig090_read(.mig090_csv_path(input_dir, "INPUT-corrections"), .mig090_corr_cols)
  values <- .mig090_correct(values, corr)
  if (anyNA(files$hash) || anyDuplicated(files$hash) || anyNA(files$staged_name) || anyDuplicated(files$staged_name) ||
      anyNA(files$report_no))
    .mig090_fail("INPUT-files misses or repeats a hash, name or report number.")
  wo <- unlist(strsplit(stats::na.omit(files$als_work_order), ";", fixed = TRUE))
  if (!all(grepl("^ES[0-9]{7}$", wo))) .mig090_fail("INPUT-files holds an ALS work order that is not ES + 7 digits.")
  if (!all(grepl("^[0-9]{8}(-[0-9A-Z]+)?$", files$report_no))) .mig090_fail("INPUT-files holds a malformed report number.")
  if (!all(values$hash %in% files$hash)) .mig090_fail("INPUT-values names a file not in INPUT-files.")
  if (!all(files$hash %in% values$hash)) .mig090_fail("INPUT-files lists a file with no values.")
  if (anyNA(values[, c("hash", "source_ref", "feature_raw", "sample_datetime_raw", "label")]))
    .mig090_fail("INPUT-values misses a required value.")
  if (anyDuplicated(values[, c("hash", "source_ref")])) .mig090_fail("INPUT-values repeats a source_ref.")
  unmapped <- unique(values$feature_raw[is.na(.mig090_point_of(values$feature_raw))])
  if (length(unmapped)) .mig090_fail(sprintf("printed site(s) not in .mig090_points: %s", paste(unmapped, collapse = "; ")))
  if (any(grepl("^(K|B)\\.J", .mig090_points$feature))) .mig090_fail("the mapping names an excluded point.")
  unknown <- setdiff(unique(values$label), .mig090_labels$printed)
  if (length(unknown)) .mig090_fail(sprintf("unlisted label(s): %s", paste(unknown, collapse = "; ")))
  n_by_file <- table(factor(values$hash, levels = files$hash))
  if (!identical(as.integer(n_by_file), as.integer(files$n_values)))
    .mig090_fail("INPUT-files n_values does not match INPUT-values.")
  if (anyNA(alias) || anyDuplicated(paste(.rc_feature_key(alias$name), alias$date_start)))
    .mig090_fail("INPUT-alias misses or repeats a value.")
  if (!all(alias$feature %in% .mig090_points$feature)) .mig090_fail("INPUT-alias names a feature outside .mig090_points.")
  if (!identical(alias$feature, .mig090_point_of(alias$name)))
    .mig090_fail("INPUT-alias maps a name to a feature other than .mig090_points does.")
  if (any(as.Date(alias$date_start) > as.Date(alias$date_end))) .mig090_fail("INPUT-alias has start > end.")
  list(files = files, values = values, alias = alias, corrections = corr)
}

# INPUT-values holds each cell as printed; INPUT-corrections lists the few printed
# units/dates that are evidently wrong or missing, and values withheld ("_"),
# each with its reason. A
# correction applies to the cells of one file, printed site (or "*") and label
# (or "*") whose `field` equals `printed` (NA = empty); one that matches no cell
# aborts the run.
.mig090_correct <- function(values, corr) {
  if (anyNA(corr[, c("hash", "feature_raw", "label", "field", "corrected", "reason")]))
    .mig090_fail("INPUT-corrections misses a value.")
  if (!all(corr$field %in% c("units_raw", "sample_datetime_raw", "value_raw")))
    .mig090_fail("INPUT-corrections may change only units_raw, sample_datetime_raw or value_raw.")
  if (any(corr$field == "value_raw" & corr$corrected != "_"))
    .mig090_fail("INPUT-corrections may only withhold a printed value (value_raw -> _), never replace it.")
  for (i in seq_len(nrow(corr))) {
    c1 <- corr[i, ]
    cur <- values[[c1$field]]
    hit <- values$hash == c1$hash & (c1$feature_raw == "*" | values$feature_raw == c1$feature_raw) &
      (c1$label == "*" | values$label == c1$label) &
      (if (is.na(c1$printed)) is.na(cur) else (!is.na(cur) & cur == c1$printed))
    if (!any(hit)) .mig090_fail(sprintf("INPUT-corrections row %d matches no cell.", i))
    values[[c1$field]][hit] <- c1$corrected
  }
  values
}

mig090_read_trim <- function(trim_csv, files) {
  t <- .mig090_read(trim_csv, .mig090_trim_cols)
  if (anyNA(t[, c("hash", "trim_record", "trim_uri", "container", "title", "record_date")]))
    .mig090_fail("the TRIM CSV misses a value.")
  if (anyDuplicated(t$hash) || !setequal(t$hash, files$hash))
    .mig090_fail("the TRIM CSV must hold exactly one row per imported file.")
  t
}

# ---- the operator adapter ---------------------------------------------------------

.mig090_day_of <- function(raw) {
  d <- as.Date(raw, format = "%d %b %Y")
  if (anyNA(d)) .mig090_fail(sprintf("unparseable sample_datetime_raw: %s", paste(unique(raw[is.na(d)]), collapse = ", ")))
  d
}
.mig090_ref_order <- function(ref) {
  # source_ref "p<page>!y<pos>!<site>" (text layer) or "p<page>!r<row>!<site>" (scans)
  pg <- as.integer(sub("^p([0-9]+)!.*$", "\\1", ref))
  pos <- as.numeric(sub("^p[0-9]+![yr]([0-9.]+)!.*$", "\\1", ref))
  order(pg, pos, ref)
}

.mig090_parse_one <- function(fh, files, v, tag) {
  f <- files[files$hash == fh, , drop = FALSE]
  v <- v[.mig090_ref_order(v$source_ref), , drop = FALSE]
  # one sample per mapped point and day: a column whose heading changes between
  # pages ("LB12/DP1" on one page, "LB12" on the next) is one sample
  v$lab_sample_id <- sprintf("%s!%s!%s", f$report_no, .mig090_point_of(v$feature_raw),
                             gsub("[^0-9A-Za-z]", "", v$sample_datetime_raw))
  lab <- .mig090_labels$analyte_raw[match(v$label, .mig090_labels$printed)]
  rows <- list(); skipped <- list(); obs <- list(); seen <- character(0)
  skip <- function(i, why) skipped[[length(skipped) + 1]] <<- tibble::tibble(source_ref = v$source_ref[[i]], reason = why)
  for (i in seq_len(nrow(v))) {
    val <- if (is.na(v$value_raw[[i]])) "" else trimws(v$value_raw[[i]])
    if (identical(lab[[i]], "<obs>")) {
      if (!val %in% .mig090_not_reported) obs[[v$lab_sample_id[[i]]]] <- list(ref = v$source_ref[[i]], text = val)
      next
    }
    if (val %in% .mig090_not_reported) { skip(i, "not_reported"); next }
    if (!nzchar(lab[[i]])) { skip(i, "label_not_imported"); next }
    key <- paste(v$lab_sample_id[[i]], lab[[i]])
    if (key %in% seen) { skip(i, "repeated_label"); next }
    seen <- c(seen, key)
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

mig090_adapter <- function(inp) {
  tag <- paste0(.mig090_adapter_id, "/", .mig090_adapter_version)
  by_hash <- split(inp$values, inp$values$hash)
  list(id = .mig090_adapter_id, version = .mig090_adapter_version,
       match = function(file_meta) if (isTRUE(file_meta$hash %in% inp$files$hash)) "exact" else "no",
       parse = function(path, file_meta) {
         if (!isTRUE(file_meta$hash %in% inp$files$hash)) .mig090_fail("parse() called on an unplanned file.")
         .mig090_parse_one(file_meta$hash, inp$files, by_hash[[file_meta$hash]], tag)
       })
}

# What the adapter emits for every file (no DB): the parse dry run.
mig090_parse_all <- function(inp) {
  ad <- mig090_adapter(inp)
  out <- lapply(inp$files$hash, function(h) ad$parse(NA_character_, list(hash = h)))
  names(out) <- inp$files$hash
  out
}

# The point-days the adapter creates samples for (feature, day), from the parse.
mig090_planned_point_days <- function(parsed) {
  s <- dplyr::bind_rows(lapply(parsed, function(p) p$samples))
  unique(data.frame(feature = .mig090_point_of(s$feature_raw), feature_raw = s$feature_raw,
                    day = .mig090_day_of(s$sample_datetime_raw), stringsAsFactors = FALSE))
}

# ---- preconditions shared by CHECK and run ---------------------------------------------

# Point-days already holding a sample, and the report cells against what is stored
# there (Robin: import only what is not already in the database; list any
# disagreement, never change the stored value).
mig090_overlap <- function(con, inp, parsed) {
  pd <- mig090_planned_point_days(parsed)
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE m090_pd (feature VARCHAR, day DATE)")
  DBI::dbAppendTable(con, "m090_pd", unique(pd[, c("feature", "day")]))
  DBI::dbGetQuery(con, sprintf("
    SELECT f.name AS feature, %s AS day, s.uuid AS sample, s.organisation, p.name AS project, lm.name AS lab_method,
           lm.organisation AS lab_org, a.value, a.value_chr
    FROM sample s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    JOIN m090_pd pd ON pd.feature = f.name AND pd.day = %s
    LEFT JOIN project p ON p.uuid = s.uuid_project LEFT JOIN analysis a ON a.uuid_sample = s.uuid
    LEFT JOIN lab_method lm ON lm.uuid = a.uuid_lab ORDER BY 1, 2, 6",
    .mig090_syd("coalesce(s.date, s.datetime)"), .mig090_syd("coalesce(s.date, s.datetime)")))
}

# The report cells at an overlapping point-day, set beside the stored values of the
# same lab_method name: equal -> already present, otherwise a discrepancy.
mig090_discrepancies <- function(overlap, parsed) {
  empty <- data.frame(feature = character(0), day = character(0), report_no = character(0), lab_method = character(0),
                      report_value = character(0), stored_value = character(0), status = character(0))
  if (!nrow(overlap)) return(empty)
  r <- dplyr::bind_rows(lapply(parsed, function(p) p$results))
  r$feature <- .mig090_point_of(r$feature_raw)
  r$day <- vapply(strsplit(r$lab_sample_id, "!", fixed = TRUE), function(z) z[[3]], "")
  r$day <- format(as.Date(r$day, format = "%d%b%Y"))
  ov <- overlap; ov$day <- format(as.Date(ov$day))
  r <- merge(r, unique(ov[, c("feature", "day")]))
  if (!nrow(r)) return(empty)
  out <- lapply(seq_len(nrow(r)), function(i) {
    st <- ov[ov$feature == r$feature[[i]] & ov$day == r$day[[i]] & !is.na(ov$lab_method) & ov$lab_method == r$analyte_raw[[i]], ]
    sv <- if (nrow(st)) paste(ifelse(is.na(st$value), st$value_chr, format(st$value)), collapse = "; ") else NA_character_
    same <- nrow(st) && (any(!is.na(st$value) & !is.na(r$value_num[[i]]) & abs(st$value - r$value_num[[i]]) < 1e-9) ||
                           any(!is.na(st$value_chr) & identical(st$value_chr, r$value_chr[[i]])))
    data.frame(feature = r$feature[[i]], day = r$day[[i]], report_no = r$work_order[[i]], lab_method = r$analyte_raw[[i]],
               report_value = r$value_raw[[i]], stored_value = sv,
               status = if (!nrow(st)) "not_stored" else if (same) "equal" else "differs")
  })
  do.call(rbind, out)
}

# Cited ALS work orders that already hold ALS results: those originals would make
# the ACIRL transcriptions duplicates.
mig090_als_held <- function(con, inp) {
  wo <- unique(unlist(strsplit(stats::na.omit(inp$files$als_work_order), ";", fixed = TRUE)))
  DBI::dbGetQuery(con, sprintf("SELECT p.name, count(*) AS n FROM analysis a JOIN sample s ON s.uuid = a.uuid_sample
    JOIN project p ON p.uuid = s.uuid_project JOIN lab_method lm ON lm.uuid = a.uuid_lab
    WHERE p.name IN %s AND lm.organisation <> 'ACIRL' GROUP BY 1", .mig090_inlist(wo)))
}

# The 089 PDFs: archived by 089's adapter (to be reset), already reset (`seen`),
# or not known (the new file).
mig090_file_states <- function(con, inp) {
  st <- DBI::dbGetQuery(con, sprintf("SELECT hash, state, state_reason, adapter FROM ingest_file WHERE hash IN %s",
                                     .mig090_inlist(inp$files$hash)))
  st[match(inp$files$hash, st$hash), , drop = FALSE]
}

# ---- phase A: aliases + feature date_start ---------------------------------------

.mig090_uuid <- function(...) {
  d <- digest::digest(paste(c(.mig090_marker_version, ...), collapse = "\u001f"), algo = "md5", serialize = FALSE)
  paste(substr(d, 1, 8), substr(d, 9, 12), paste0("4", substr(d, 14, 16)),
        paste0("8", substr(d, 18, 20)), substr(d, 21, 32), sep = "-")
}

# Planned on the samples the adapter emits (a column that prints only "----" or
# "Not Discharging" creates no sample, so its name needs no alias).
mig090_plan_registry <- function(con, inp, parsed) {
  feats <- unique(.mig090_points$feature)
  feat <- DBI::dbGetQuery(con, sprintf("SELECT uuid, name, date_start, date_end, comments FROM feature WHERE name IN %s",
                                       .mig090_inlist(feats)))
  if (nrow(feat) != length(feats) || anyDuplicated(feat$name)) .mig090_fail("a mapped feature does not exist exactly once.")
  a <- inp$alias
  a$uuid_feature <- feat$uuid[match(a$feature, feat$name)]
  a$alias_key <- .rc_feature_key(a$name)
  a$uuid <- mapply(.mig090_uuid, a$alias_key, a$feature, a$date_start, a$date_end, USE.NAMES = FALSE)
  a$comments <- sprintf("090: ACIRL whole-site report history %s..%s (%s = %s; checked against ACIRL 24006990-08)",
                        a$date_start, a$date_end, a$name, a$feature)
  v <- mig090_planned_point_days(parsed)
  first <- tapply(v$day, v$feature, min)
  fd <- data.frame(feature = names(first), stringsAsFactors = FALSE)
  fd$uuid <- feat$uuid[match(fd$feature, feat$name)]
  fd$first <- as.Date(unname(first), origin = "1970-01-01")
  fd$old_start <- as.Date(feat$date_start[match(fd$feature, feat$name)])
  fd$date_end <- as.Date(feat$date_end[match(fd$feature, feat$name)])
  fd$old_comments <- feat$comments[match(fd$feature, feat$name)]
  fd <- fd[!is.na(fd$old_start) & fd$old_start > fd$first, , drop = FALSE]
  fd$new_comments <- paste0(ifelse(is.na(fd$old_comments), "", paste0(fd$old_comments, "; ")), sprintf(
    "090: date_start moved back from %s to %s for the ACIRL whole-site report history.", fd$old_start, fd$first))
  list(alias = a, feature = fd, values = v[, c("feature_raw", "feature", "day")],
       date_end = feat[, c("name", "date_end")])
}

.mig090_alias_rows <- function(a) {
  tibble::tibble(
    uuid = a$uuid, uuid_feature = a$uuid_feature, name = a$name, alias_key = a$alias_key, kind = "descriptive",
    n_seen = 0L, auto_assign = TRUE,
    first_seen = as.POSIXct(rep(NA_real_, nrow(a)), origin = "1970-01-01", tz = "UTC"),
    last_seen = as.POSIXct(rep(NA_real_, nrow(a)), origin = "1970-01-01", tz = "UTC"),
    confirmed_by = .mig090_confirmed_by, comments = a$comments,
    date_start = as.Date(a$date_start), date_end = as.Date(a$date_end))
}

# Every (printed name, day) must resolve, through the arms in force on that day
# (the existing ones plus the planned ones), to its mapped feature and to no other.
mig090_resolution <- function(con, plan) {
  pv <- unique(plan$values)
  pv$key <- .rc_feature_key(pv$feature_raw)
  arms <- DBI::dbGetQuery(con, sprintf("SELECT fa.uuid, fa.alias_key, f.name AS feature, fa.date_start, fa.date_end
    FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature WHERE fa.alias_key IN %s", .mig090_inlist(pv$key)))
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

# Problems that stop phase A: a printed name that would not resolve to exactly its
# mapped feature; a planned arm overlapping an existing arm of the same key to
# another feature; a mapped feature retired before an imported day.
mig090_registry_problems <- function(con, plan) {
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
  res <- mig090_resolution(con, plan)
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

mig090_apply_registry <- function(con, plan, logf) {
  db_transaction(con, function(con) {
    todo <- plan$alias[!plan$alias$uuid %in% DBI::dbGetQuery(con, sprintf(
      "SELECT uuid FROM feature_alias WHERE uuid IN %s", .mig090_inlist(plan$alias$uuid)))$uuid, , drop = FALSE]
    if (nrow(todo)) db_append(con, "feature_alias", .mig090_alias_rows(todo), actor = .mig090_actor,
                              reason = "090: Katoomba whole-site report history aliases")
    fd <- plan$feature
    for (i in seq_len(nrow(fd))) {
      cur <- as.Date(DBI::dbGetQuery(con, "SELECT date_start FROM feature WHERE uuid = ?", params = list(fd$uuid[[i]]))[[1]])
      if (is.na(cur) || cur <= fd$first[[i]]) next
      db_update(con, "feature", uuid = fd$uuid[[i]],
                changes = list(date_start = fd$first[[i]], comments = fd$new_comments[[i]]),
                actor = .mig090_actor, reason = "090: Katoomba history - date_start covers the imported samples")
    }
    logf("Phase A: %d alias arm(s) inserted (%d already present); %d feature date_start(s) moved.", nrow(todo),
         nrow(plan$alias) - nrow(todo), nrow(fd))
    NULL
  })
}

# ---- phase B0: reset the 089-held PDFs ----------------------------------------------

mig090_apply_reset <- function(con, inp, recorded_at, logf) {
  db_transaction(con, function(con) {
    st <- mig090_file_states(con, inp)
    todo <- st[!is.na(st$hash) & st$state == "archived" & !is.na(st$adapter) & st$adapter == .mig090_prior_adapter, ,
               drop = FALSE]
    for (i in seq_len(nrow(todo))) {
      ingest_file_set_state(con, todo$hash[[i]], "seen", reason = NA_character_, reset = TRUE)
      old <- list(state = todo$state[[i]], state_reason = todo$state_reason[[i]])
      for (f in c("state", "state_reason")) {
        .st_write_change_log(con, at = recorded_at, actor = .mig090_actor, action = "update", tbl = "ingest_file",
                             uuid_row = NA_character_, field = f, old = old[[f]],
                             new = if (f == "state") "seen" else NA_character_,
                             reason = "090: re-route the 089 report so its non-MP columns are imported (reset = TRUE)",
                             source_hash = todo$hash[[i]])
      }
    }
    logf("Phase B0: %d ingest_file row(s) reset archived -> seen.", nrow(todo))
    NULL
  })
}

# ---- phase B: the import --------------------------------------------------------

mig090_stage <- function(inp, files_dir, inbox) {
  if (dir.exists(inbox) && length(list.files(inbox, all.files = TRUE, no.. = TRUE)))
    .mig090_fail(sprintf("staging inbox %s is not empty.", inbox))
  dir.create(inbox, recursive = TRUE, showWarnings = FALSE)
  for (i in seq_len(nrow(inp$files))) {
    src <- file.path(files_dir, inp$files$staged_name[[i]])
    if (!file.exists(src)) .mig090_fail(sprintf("source file %s not found.", src))
    if (!identical(hash_file(src), inp$files$hash[[i]])) .mig090_fail(sprintf("%s: hash differs from INPUT.", src))
    dest <- file.path(inbox, inp$files$staged_name[[i]])
    if (!file.copy(src, dest, copy.date = TRUE)) .mig090_fail(sprintf("could not stage %s.", src))
    if (!identical(hash_file(dest), inp$files$hash[[i]])) .mig090_fail(sprintf("%s: staged copy differs.", dest))
  }
  invisible(inbox)
}

mig090_import <- function(db, inp, inbox, archive_dir, snapshot_dir, logf, dry_run = FALSE) {
  withr::local_options(sampletidy.archive_dir = archive_dir, sampletidy.snapshot_dir = snapshot_dir,
                       sampletidy.remove_ingested = FALSE, sampletidy.input_dir = inbox)
  if (!identical(st_config("archive_dir"), archive_dir) || isTRUE(as.logical(st_config("remove_ingested"))))
    .mig090_fail("the import configuration did not take.")
  register_adapter(mig090_adapter(inp))
  on.exit({ clear_adapters(); register_builtin_adapters() }, add = TRUE)
  rep <- ingest_dir(inbox, db = db, dry_run = dry_run)
  logf("Phase B: ingest_dir(dry_run = %s): events %s, committed %s, failed %s, rows new %s, already %s, skipped %s, review %s",
       dry_run, rep$n_events, rep$n_events_committed, rep$events_failed, rep$rows_new, rep$rows_already_present,
       rep$rows_skipped, rep$review_items_opened)
  rep
}

# ---- phase C: TRIM filing adoption + marker ---------------------------------------

mig090_filing_plan <- function(con, inp, trim) {
  a <- DBI::dbGetQuery(con, sprintf("SELECT a.uuid, a.hash, a.filename FROM asset a WHERE a.hash IN %s",
                                    .mig090_inlist(inp$files$hash)))
  if (nrow(a) != nrow(inp$files) || anyDuplicated(a$hash)) .mig090_fail("each imported PDF must be exactly one asset.")
  x <- merge(trim, a, by = "hash")
  x <- x[match(inp$files$hash, x$hash), , drop = FALSE]
  f <- DBI::dbGetQuery(con, sprintf("SELECT uuid_asset, external_id FROM asset_filing WHERE system = '%s' AND uuid_asset IN %s",
                                    .mig090_trim_system, .mig090_inlist(x$uuid)))
  x$filed_as <- f$external_id[match(x$uuid, f$uuid_asset)]
  x
}

mig090_apply_filing <- function(con, plan, recorded_at, logf) {
  db_transaction(con, function(con) {
    if (any(!is.na(plan$filed_as) & plan$filed_as != plan$trim_record))
      .mig090_fail("an asset is already filed in TRIM under a different record than the TRIM CSV says.")
    todo <- plan[is.na(plan$filed_as), , drop = FALSE]
    res <- vapply(seq_len(nrow(todo)), function(i) {
      register_filing(con, uuid_asset = todo$uuid[[i]], system = .mig090_trim_system,
                      external_id = todo$trim_record[[i]], external_uri = todo$trim_uri[[i]],
                      container = todo$container[[i]],
                      filed_at = as.POSIXct(paste(todo$record_date[[i]], "00:00:00"), tz = "Australia/Sydney"),
                      title = todo$title[[i]],
                      comments = "090: already in TRIM before the import (adopted; never file again)")
    }, character(1))
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig090_marker_version, recorded_at))
    logf("Phase C: filings inserted %d (%d already filed by 089); marker %d.", sum(res == "inserted"),
         sum(!is.na(plan$filed_as)), .mig090_marker_version)
    res
  })
}

# ---- verification -------------------------------------------------------------------

.mig090_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analyte", "lab_method", "analysis", "sample", "project", "asset",
            "review_queue", "ingest_file", "change_log", "schema_version")
  if ("asset_filing" %in% DBI::dbListTables(con)) tabs <- c(tabs, "asset_filing")
  stats::setNames(vapply(tabs, function(t) .mig090_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t)), 0L), tabs)
}

# Content digest of the samples and analyses that existed before the import.
.mig090_existing_digest <- function(con) {
  s <- DBI::dbGetQuery(con, "SELECT * FROM sample ORDER BY uuid")
  a <- DBI::dbGetQuery(con, "SELECT * FROM analysis ORDER BY uuid")
  c(sample = digest::digest(s, algo = "sha1"), analysis = digest::digest(a, algo = "sha1"))
}

# After the import: the new rows, by content (uuids differ run to run).
mig090_new_rows <- function(con, before_samples) {
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE m090_old (uuid VARCHAR)")
  DBI::dbAppendTable(con, "m090_old", data.frame(uuid = before_samples, stringsAsFactors = FALSE))
  DBI::dbGetQuery(con, sprintf("
    SELECT f.name AS feature, fa.name AS alias, %s AS day, s.datetime, s.organisation, p.name AS project,
           pp.name AS parent, lm.name AS lab_method, lm.method, an.name AS analyte, a.value, a.value_chr,
           a.quantified, s.comments AS sample_comments
    FROM sample s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias LEFT JOIN feature f ON f.uuid = fa.uuid_feature
    LEFT JOIN project p ON p.uuid = s.uuid_project LEFT JOIN project pp ON pp.uuid = p.uuid_parent
    LEFT JOIN analysis a ON a.uuid_sample = s.uuid LEFT JOIN lab_method lm ON lm.uuid = a.uuid_lab
    LEFT JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE s.uuid NOT IN (SELECT uuid FROM m090_old)
    ORDER BY feature, day, lab_method, a.value, a.value_chr", .mig090_syd("coalesce(s.date, s.datetime)")))
}

mig090_verify_import <- function(con, inp, parsed, before) {
  pr <- character(0)
  st <- mig090_file_states(con, inp)
  if (anyNA(st$hash) || !all(st$state == "archived") || !all(st$adapter == .mig090_adapter_id))
    pr <- c(pr, sprintf("not every PDF is archived by %s: %s", .mig090_adapter_id,
                        paste(unique(paste(st$state, st$state_reason, st$adapter)), collapse = "; ")))
  na <- .mig090_scalar(con, sprintf("SELECT COUNT(*) FROM asset WHERE hash IN %s", .mig090_inlist(inp$files$hash)))
  if (na != nrow(inp$files)) pr <- c(pr, sprintf("%d asset rows for %d PDFs", na, nrow(inp$files)))
  nr <- mig090_new_rows(con, before$samples)
  pd <- mig090_planned_point_days(parsed)
  got <- unique(data.frame(feature = nr$feature, day = as.Date(nr$day)))
  if (nrow(merge(got, pd[, c("feature", "day")])) != nrow(got) || anyNA(got$feature))
    pr <- c(pr, "a new sample is at a feature or on a day the adapter did not plan")
  n_emitted <- sum(vapply(parsed, function(p) nrow(p$results), 0L))
  n_new <- sum(!is.na(nr$lab_method))
  if (n_new != n_emitted) pr <- c(pr, sprintf("%d new analyses, %d rows emitted", n_new, n_emitted))
  n_smp <- sum(vapply(parsed, function(p) nrow(p$samples), 0L))
  if (nrow(unique(nr[, c("feature", "day", "datetime", "project")])) != n_smp)
    pr <- c(pr, sprintf("%d new samples, %d emitted", nrow(unique(nr[, c("feature", "day", "datetime", "project")])), n_smp))
  old <- DBI::dbGetQuery(con, sprintf("SELECT * FROM sample WHERE uuid IN (SELECT uuid FROM m090_old) ORDER BY uuid"))
  if (!identical(digest::digest(old, algo = "sha1"), before$digest[["sample"]])) pr <- c(pr, "an existing sample changed")
  olda <- DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s ORDER BY uuid", "(SELECT uuid FROM m090_olda)"))
  if (!identical(digest::digest(olda, algo = "sha1"), before$digest[["analysis"]])) pr <- c(pr, "an existing analysis changed")
  list(problems = pr, new_rows = nr)
}

# ---- backup ------------------------------------------------------------------------

mig090_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig090_name,
                                          format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")))
  n0 <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    n <- .mig090_counts(con)
    if (!isTRUE(file.copy(db, dest, overwrite = FALSE))) .mig090_fail(sprintf("could not write backup %s", dest))
    n
  }, db = db)
  v <- DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE)
  on.exit(DBI::dbDisconnect(v, shutdown = TRUE), add = TRUE)
  if (!identical(n0, .mig090_counts(v))) .mig090_fail("backup verification failed: counts differ.")
  dest
}

.mig090_write_csv <- function(df, path) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(df)) .mig090_fail(sprintf("CSV %s did not round-trip.", basename(path)))
}

# ---- run -------------------------------------------------------------------------------

mig090_run <- function(db, snapshot_dir, archive_dir, work_dir, files_dir, trim_csv, dry_run = FALSE,
                       csv_dir = "dev/migrations", input_dir = "dev/migrations", requires = .mig090_requires,
                       .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", basename(db), sprintf(fmt, ...)))
  checkmate::assert_directory_exists(archive_dir)
  checkmate::assert_directory_exists(snapshot_dir)
  checkmate::assert_directory_exists(csv_dir)
  inp <- mig090_read_inputs(input_dir)
  trim <- mig090_read_trim(trim_csv, inp$files)
  parsed <- mig090_parse_all(inp)
  logf("Inputs: %d PDF(s), %d transcribed cell(s), %d alias arm(s); adapter emits %d result row(s), %d sample(s).",
       nrow(inp$files), nrow(inp$values), nrow(inp$alias), sum(vapply(parsed, function(p) nrow(p$results), 0L)),
       sum(vapply(parsed, function(p) nrow(p$samples), 0L)))

  con <- st_connect(db, read_only = TRUE)
  st <- tryCatch({
    have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
    if (!all(requires %in% have)) .mig090_fail(sprintf("marker %s required first.", paste(requires, collapse = ", ")))
    list(done = .mig090_marker_version %in% have, plan = mig090_plan_registry(con, inp, parsed))
  }, finally = DBI::dbDisconnect(con, shutdown = TRUE))

  if (st$done) {
    con <- st_connect(db, read_only = TRUE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    fp <- mig090_filing_plan(con, inp, trim)
    if (anyNA(fp$filed_as) || !identical(fp$filed_as, fp$trim_record)) .mig090_fail("re-verify: filing rows are not as planned.")
    fs <- mig090_file_states(con, inp)
    if (anyNA(fs$hash) || !all(fs$state == "archived")) .mig090_fail("re-verify: a PDF is not archived.")
    logf("090 already applied; re-verified; nothing to do.")
    return(invisible(list(status = "already_migrated")))
  }

  con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    pr <- mig090_registry_problems(con, st$plan)
    ov <- mig090_overlap(con, inp, parsed)
    als <- mig090_als_held(con, inp)
    fs <- mig090_file_states(con, inp)
    list(problems = pr, overlap = ov, als = als, states = fs,
         before_samples = DBI::dbGetQuery(con, "SELECT uuid FROM sample")$uuid,
         before_analyses = DBI::dbGetQuery(con, "SELECT uuid FROM analysis")$uuid,
         digest = .mig090_existing_digest(con))
  }, finally = DBI::dbDisconnect(con, shutdown = TRUE))
  disc <- mig090_discrepancies(pre$overlap, parsed)
  .mig090_write_csv(disc, .mig090_csv_path(csv_dir, "DISCREPANCIES"))
  if (length(pre$problems)) .mig090_fail(paste(pre$problems, collapse = "; "))
  if (nrow(pre$overlap)) .mig090_fail(sprintf("%d stored row(s) at planned point-days (see DISCREPANCIES CSV); resolve first.",
                                              nrow(pre$overlap)))
  if (nrow(pre$als)) .mig090_fail(sprintf("cited ALS work order(s) already hold ALS results: %s",
                                          paste(pre$als$name, collapse = ", ")))
  odd <- pre$states[!is.na(pre$states$hash) & !(pre$states$state %in% c("archived", "seen")), , drop = FALSE]
  if (nrow(odd)) .mig090_fail(sprintf("unexpected ingest_file state(s): %s", paste(unique(odd$state), collapse = ", ")))
  logf("Plan: %d alias arm(s); %d date_start move(s); %d ingest_file reset(s); %d file(s) new to the database.",
       nrow(st$plan$alias), nrow(st$plan$feature),
       sum(!is.na(pre$states$hash) & pre$states$state == "archived" & pre$states$adapter == .mig090_prior_adapter),
       sum(is.na(pre$states$hash)))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: inputs, parse, overlap and registry preconditions checked. Nothing written.")
    return(invisible(list(status = "dry_run", parsed = parsed, plan = st$plan)))
  }

  # backups: the ingest_file rows that are reset and the features that change, then the whole file
  con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig090_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM ingest_file WHERE hash IN %s ORDER BY hash",
                                                   .mig090_inlist(inp$files$hash))),
                      .mig090_csv_path(csv_dir, "BACKUP-ingest_file"))
    .mig090_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM feature WHERE name IN %s ORDER BY name",
                                                   .mig090_inlist(.mig090_points$feature))),
                      .mig090_csv_path(csv_dir, "BACKUP-feature"))
  }, finally = DBI::dbDisconnect(con, shutdown = TRUE))
  backup_path <- mig090_backup(db, snapshot_dir, .now)
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: cp %s %s", shQuote(backup_path), shQuote(db))
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) mig090_apply_registry(con, st$plan, logf), db = db)
  .mig090_write_csv(as.data.frame(.mig090_alias_rows(st$plan$alias)), .mig090_csv_path(csv_dir, "INSERTED-feature_alias"))
  with_db_write(function(con) mig090_apply_reset(con, inp, recorded_at, logf), db = db)

  inbox <- file.path(work_dir, "inbox")
  unlink(inbox, recursive = TRUE)
  mig090_stage(inp, files_dir, inbox)
  rep <- mig090_import(db, inp, inbox, archive_dir, snapshot_dir, logf)

  con <- st_connect(db, read_only = TRUE)
  ver <- tryCatch({
    DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE m090_olda (uuid VARCHAR)")
    DBI::dbAppendTable(con, "m090_olda", data.frame(uuid = pre$before_analyses, stringsAsFactors = FALSE))
    mig090_verify_import(con, inp, parsed, list(samples = pre$before_samples, digest = pre$digest))
  }, finally = DBI::dbDisconnect(con, shutdown = TRUE))
  .mig090_write_csv(ver$new_rows, file.path(work_dir, sprintf("%s-NEW-rows.csv", .mig090_name)))
  if (length(ver$problems)) .mig090_fail(paste0("import verify: ", paste(ver$problems, collapse = "; "),
                                                ". Restore from ", backup_path))

  res <- with_db_write(function(con) {
    fp <- mig090_filing_plan(con, inp, trim)
    mig090_apply_filing(con, fp, recorded_at, logf)
  }, db = db)
  logf("%s migrated successfully (marker %d).", .mig090_name, .mig090_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, report = rep, new_rows = ver$new_rows,
                 filings = res))
}
