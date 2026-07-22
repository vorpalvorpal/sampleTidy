# Plan 04 - the `esdat` adapter: ESdat (EScIS) lab EDD deliveries. One
# "delivery" is up to three files sharing a filename stem
# (`Chemistry2e.CSV`, `Sample2e.CSV`, `Header.XML`); this adapter parses each
# file **independently** (assembly, plan 07, joins them back together).

# Pinned header fingerprints (A15/R-4.1) - compared byte-for-byte,
# case-sensitive, against the first-line field names of a candidate CSV.
.st_esdat_chem_header <- c(
  "SampleCode", "ChemCode", "OriginalChemName", "Prefix", "Result",
  "Result_Unit", "Total_or_Filtered", "Result_Type", "Method_Type",
  "Method_Name", "Extraction_Date", "Analysed_Date", "EQL", "EQL_Units",
  "Comments", "Lab_Qualifier", "UCL", "LCL"
)
.st_esdat_sample_header <- c(
  "SampleCode", "Sampled_Date_Time", "Field_ID", "Blank1", "Depth", "Blank2",
  "Matrix_Type", "Sample_Type", "Parent_Sample", "Blank3", "SDG", "Lab_Name",
  "Lab_SampleID", "Lab_Comments", "Lab_Report_Number"
)

# work_order is extracted from SampleCode as an *anchored* prefix (R-4.2) -
# deliberately distinct from file-meta.R's unanchored `.st_work_order_re`,
# which scans a whole filename rather than the start of a sample code.
.st_esdat_work_order_re <- "^[A-Z]{2}\\d{7}"
.st_esdat_cas_re <- "^\\d{2,7}-\\d{2}-\\d$"

#' Construct the `esdat` adapter
#'
#' ESdat (EScIS) lab EDD adapter (DESIGN section 5, PLAN-04). Registered under id
#' `"esdat"` by [register_builtin_adapters()] in `R/zzz.R`.
#'
#' @return a list with elements `id`, `version`, `match`, `parse` (the
#'   adapter shape validated by [register_adapter()]).
#' @keywords internal
#' @noRd
esdat_adapter <- function() {
  version <- "1.0"
  list(
    id = "esdat",
    version = version,
    match = function(file_meta) .st_esdat_match(file_meta),
    parse = function(path, file_meta) .st_esdat_parse(path, file_meta, version)
  )
}

# --- R-4.1 match() ----------------------------------------------------------

.st_esdat_match <- function(fm) {
  if (identical(fm$ext, "xml")) {
    if (isTRUE(grepl("escis.com.au", fm$peek, fixed = TRUE))) {
      return("exact")
    }
    return("no")
  }

  if (identical(fm$ext, "csv")) {
    header <- tryCatch(.st_esdat_read_header(fm$path), error = function(e) NULL)
    if (is.null(header)) {
      return("no")
    }
    if (identical(header, .st_esdat_chem_header) ||
      identical(header, .st_esdat_sample_header)) {
      return("exact")
    }
    return("no")
  }

  "no"
}

# First-line field names of a CSV, read with every column forced to
# character (avoids type-guessing surprises on header-only reads). Real
# Chemistry2e/Sample2e CSVs are latin-1 (A35), so the read always uses a
# latin-1 locale - readr strips a literal UTF-8 BOM at the byte level before
# applying that locale (verified empirically), but `.st_strip_bom()` is kept
# as a defensive second layer over the first header cell per PLAN-04.
# Read an ESdat CSV with the symmetric encoding fallback (R-4.2/A35). Real
# Chemistry2e/Sample2e CSVs are genuinely latin-1 (bytes 0xB0/0xB5), so latin-1
# stays the PRIMARY encoding and a clean file (zero mojibake probe) is never
# re-read - the UTF-8 alternate is a no-op except on a genuinely mis-encoded
# file. `...` carries per-call args (e.g. `n_max = 0` for the header read).
.st_esdat_read_csv <- function(path, filename, ...) {
  extra <- list(...)
  read_one <- function(enc) {
    args <- c(
      list(
        path,
        col_types = readr::cols(.default = readr::col_character()),
        locale = readr::locale(encoding = enc),
        show_col_types = FALSE
      ),
      extra
    )
    do.call(readr::read_csv, args)
  }
  .st_read_grid_with_encoding_fallback(
    read_fn = read_one,
    primary_encoding = "latin1",
    alternate_encoding = "UTF-8",
    text_extractor = function(d) unlist(d, use.names = FALSE),
    source_label = filename
  )
}

.st_esdat_read_header <- function(path, filename = basename(path)) {
  df <- .st_esdat_read_csv(path, filename, n_max = 0)
  nms <- names(df)
  if (length(nms) >= 1) {
    nms[1] <- .st_strip_bom(nms[1])
  }
  nms
}

# Defensive BOM strip (A35): guards against a UTF-8 BOM (bytes EF BB BF)
# surviving onto the first header cell, whether as the single Unicode
# codepoint U+FEFF (if ever decoded as UTF-8) or as its latin-1 mis-decode
# "\u00ef\u00bb\u00bf" (if a latin-1 locale ever reads the raw BOM bytes
# without stripping them).
.st_strip_bom <- function(x) {
  x <- sub("^\ufeff", "", x)
  sub("^\u00ef\u00bb\u00bf", "", x)
}

# Structural sanity check shared by both ESdat CSV parsers (A27 refined / A35).
# A genuinely corrupt CSV body - e.g. an unterminated quoted field - makes
# readr/vroom silently swallow every remaining data line into one runaway field
# and yield ZERO rows with no error or warning (verified). A27/A35 require the
# adapter to fail loudly on that. We detect it *after* the read: a file that
# carries data lines beyond the header yet parsed to zero rows is corrupt. A
# legitimately empty file (header only, no data lines) is NOT flagged, and -
# unlike a raw quote-count heuristic - this never rejects a well-formed real
# file whose data legitimately contains a lone `"` (verified against the real
# corpus: one real file has an odd raw quote count yet parses cleanly to 45
# rows; a parity check would wrongly fail it).
.st_esdat_check_parseable <- function(path, df) {
  if (nrow(df) > 0L) {
    return(invisible(TRUE))
  }
  lines <- readLines(path, warn = FALSE)
  n_data_lines <- sum(nzchar(trimws(lines))) - 1L # minus the header line
  if (n_data_lines > 0L) {
    cli::cli_abort(
      "{.path {path}} has {n_data_lines} data line{?s} but parsed to zero rows -
       the CSV body is structurally corrupt (e.g. an unterminated quoted field).",
      class = "sampletidy_parse_error"
    )
  }
  invisible(TRUE)
}

# --- parse() dispatch + crash containment -----------------------------------

#' @noRd
.st_esdat_parse <- function(path, fm, version) {
  tryCatch(
    {
      if (identical(fm$ext, "xml")) {
        return(.st_esdat_parse_header(path, fm, version))
      }
      if (identical(fm$ext, "csv")) {
        header <- .st_esdat_read_header(path)
        if (identical(header, .st_esdat_chem_header)) {
          return(.st_esdat_parse_chemistry(path, fm, version))
        }
        if (identical(header, .st_esdat_sample_header)) {
          return(.st_esdat_parse_sample(path, fm, version))
        }
      }
      cli::cli_abort(
        "{.path {path}} is not a recognised ESdat Chemistry2e/Sample2e/Header
         file.",
        class = "sampletidy_parse_error"
      )
    },
    error = function(e) {
      if (inherits(e, "sampletidy_parse_error")) {
        stop(e)
      }
      cli::cli_abort(
        "Failed to parse {.path {path}} as an ESdat file: {conditionMessage(e)}",
        class = "sampletidy_parse_error",
        parent = e
      )
    }
  )
}

# --- R-4.2 Chemistry2e -> ir_results -----------------------------------------

.st_esdat_parse_chemistry <- function(path, fm, version) {
  df <- .st_esdat_read_csv(path, fm$filename)
  .st_esdat_check_parseable(path, df)
  n <- nrow(df)
  source_ref <- paste0("row", seq_len(n))

  sample_code <- df$SampleCode
  work_order <- stringr::str_extract(sample_code, .st_esdat_work_order_re)

  # NCP cross-reference detection (R-4.6, feeds PLAN-07 R-7.4).
  # NCP = "Non-Client Parent" (ESdat Electronic Lab Data Format spec): when the
  # lab runs its batch QC (a Lab Duplicate or Matrix Spike) on a field sample
  # belonging to ANOTHER client, the spec requires that parent sample's results
  # to be reported for QC auditability - with Field_ID/depth/client info stripped
  # - and its Sample_Type set to NCP. So these are another client's results, not
  # ours; they must be dropped, never committed into our dataset.
  # ESdat bundles these NCP cross-reference results from OTHER work orders into a
  # report. They are identifiable at parse time ONLY by a compound SampleCode of the shape
  # `<origWO>001_<homeWO>` (a leading work order + sequence, an underscore,
  # then the home work order). Chemistry2e carries no Sample_Type column, so
  # the authoritative sample-metadata join (assemble.R
  # `.st_join_samples_onto_results`, "always overrides sample_type") runs too
  # late to be seen by the R-7.4 multi-work-order partition, which operates on
  # this raw parser output. Mark these rows `NCP` here so that partition counts
  # them in `n_ncp_foreign` and drops them before commit, instead of leaking
  # them as `foreign_work_order` review items. `work_order` is deliberately
  # left as the ORIGINATING (foreign) WO extracted above, so the row reads as
  # foreign-AND-NCP (assemble.R:314) - do NOT rewrite it to the home WO, or the
  # row would look "own" and be wrongly committed. Every other row stays
  # `"unknown"` (filled by the later sample join). The `^[A-Z]{2}\d{7}` prefix
  # is `.st_esdat_work_order_re`, reused here so both stay consistent.
  ncp_re <- paste0(.st_esdat_work_order_re, "\\d*_[A-Z]{2}\\d{7}$")
  sample_type <- ifelse(
    !is.na(sample_code) & grepl(ncp_re, sample_code), "NCP", "unknown"
  )

  analyte_raw <- normalise_lab_text(df$OriginalChemName)
  method_raw <- normalise_lab_text(df$Method_Name)
  units_raw <- normalise_lab_text(df$Result_Unit)

  chem_code <- df$ChemCode
  cas_ok <- !is.na(chem_code) & grepl(.st_esdat_cas_re, chem_code)
  cas_number <- ifelse(cas_ok, chem_code, NA_character_)

  prefix <- ifelse(is.na(df$Prefix), "", df$Prefix)
  result <- ifelse(is.na(df$Result), "", df$Result)
  value_raw <- paste0(prefix, result)

  pv <- parse_value(value_raw)
  below_detection <- grepl("^<", trimws(value_raw))

  rl <- suppressWarnings(as.numeric(df$EQL))

  analysed_raw <- df$Analysed_Date
  analysed_dt <- parse_lab_datetime(analysed_raw, formats = "esdat")
  analysed_date <- as.Date(analysed_dt, tz = "Australia/Sydney")

  warnings_vec <- character(0)
  bad_date <- !is.na(analysed_raw) & trimws(analysed_raw) != "" & is.na(analysed_date)
  if (any(bad_date)) {
    idx <- which(bad_date)
    warnings_vec <- c(
      warnings_vec,
      sprintf(
        "%s: could not parse Analysed_Date '%s'",
        source_ref[idx], analysed_raw[idx]
      )
    )
  }

  results <- ir_results(
    source_hash = fm$hash,
    source_ref = source_ref,
    work_order = work_order,
    revision = as.integer(fm$revision_guess),
    org = "ALS",
    adapter = paste0("esdat/", version),
    lab_sample_id = sample_code,
    sample_type = sample_type,
    feature_raw = NA_character_,
    analyte_raw = analyte_raw,
    cas_number = cas_number,
    method_raw = method_raw,
    total_or_filtered = df$Total_or_Filtered,
    units_raw = units_raw,
    value_raw = value_raw,
    value_num = pv$value_num,
    value_chr = pv$value_chr,
    below_detection = below_detection,
    rl = rl,
    lab_qualifier = df$Lab_Qualifier,
    analysed_date = analysed_date,
    comments = df$Comments,
    confidence = 1
  )

  list(
    results = results,
    samples = ir_samples(),
    report = list(
      n_rows = n,
      n_by_sample_type = table(results$sample_type),
      skipped = tibble::tibble(source_ref = character(0), reason = character(0)),
      header = NULL,
      warnings = warnings_vec
    )
  )
}

# --- R-4.3 Sample2e -> ir_samples ---------------------------------------------

.st_esdat_parse_sample <- function(path, fm, version) {
  df <- .st_esdat_read_csv(path, fm$filename)
  .st_esdat_check_parseable(path, df)
  n <- nrow(df)
  source_ref <- paste0("row", seq_len(n))

  sample_code <- df$SampleCode
  work_order <- dplyr::coalesce(
    df$Lab_Report_Number,
    stringr::str_extract(sample_code, .st_esdat_work_order_re)
  )

  samples <- ir_samples(
    source_hash = fm$hash,
    source_ref = source_ref,
    work_order = work_order,
    org = "ALS",
    adapter = paste0("esdat/", version),
    lab_sample_id = sample_code,
    feature_raw = df$Field_ID,
    sample_datetime_raw = df$Sampled_Date_Time,
    sample_type = df$Sample_Type,
    parent_sample = df$Parent_Sample,
    matrix_raw = df$Matrix_Type,
    sampler = NA_character_,
    comments = df$Lab_Comments,
    confidence = 1
  )

  list(
    results = ir_results(),
    samples = samples,
    report = list(
      n_rows = n,
      n_by_sample_type = table(samples$sample_type),
      skipped = tibble::tibble(source_ref = character(0), reason = character(0)),
      header = NULL,
      warnings = character(0)
    )
  )
}

# --- R-4.4 Header.XML -> report metadata -------------------------------------

.st_esdat_parse_header <- function(path, fm, version) {
  doc <- tryCatch(
    xml2::read_xml(path),
    error = function(e) {
      cli::cli_abort(
        "Could not read {.path {path}} as XML: {conditionMessage(e)}",
        class = "sampletidy_parse_error", parent = e
      )
    }
  )

  ns_uris <- unname(xml2::xml_ns(doc))
  is_esdat <- identical(xml2::xml_name(doc), "ESdat") &&
    any(grepl("escis.com.au", ns_uris, fixed = TRUE))

  if (!isTRUE(is_esdat)) {
    cli::cli_abort(
      "{.path {path}} is not a recognised ESdat Header.XML file (missing the
       ESdat/EScIS namespace).",
      class = "sampletidy_parse_error"
    )
  }

  lab_report <- xml2::xml_find_first(doc, ".//*[local-name()='LabReport']")
  header <- list(
    work_order = xml2::xml_attr(lab_report, "Lab_Report_Number"),
    date_reported = xml2::xml_attr(lab_report, "Date_Reported"),
    project_id = xml2::xml_attr(lab_report, "Project_ID"),
    lab_name = xml2::xml_attr(lab_report, "Lab_Name")
  )

  list(
    results = ir_results(),
    samples = ir_samples(),
    report = list(
      n_rows = 0L,
      n_by_sample_type = table(character(0)),
      skipped = tibble::tibble(source_ref = character(0), reason = character(0)),
      header = header,
      warnings = character(0)
    )
  )
}
