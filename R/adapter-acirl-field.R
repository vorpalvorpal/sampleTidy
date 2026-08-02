# Plan 06 - the `acirl_field_xlsx` adapter: ACIRL monthly workbook
# (`2400-*.xls`/`.xlsx`, human-edited). One workbook holds a front-page
# sheet (report metadata), method sheets (ignored), optional dust sheets
# (detected, not parsed - A10), and per-visit "water" sheets holding a
# transposed field-data block plus copies of ALS lab results which must be
# dropped at the adapter (DESIGN Section 2.3). Reference implementation:
# WEM.data/R/new/import/read_ACIRL_field_data.R (`tidy_ACIRL_field_data`) and
# read_ACIRL_front_page.R - the layout logic is ported, the GlobalEnv/
# auto-add behaviour and the old hardcoded site-name regex are not (R-6.2:
# "No site-name regex").

# Field-data block terminator: the last row (searching column A) matching
# this pattern is the end of the transposed field-data block; below it sit
# ALS lab-result copies that must still be scanned (and dropped) - PLAN-06's
# own text says "ignore" but the fixture/tests require every such row to be
# recorded as a `lab_data_dropped` skip (CONTRACT: tests win).
.st_acirl_terminator_re <- "(^pH$|Temperature|Conductivity$|^EC$|Comments|Water)"

#' Construct the `acirl_field_xlsx` adapter
#'
#' ACIRL monthly-workbook field-data adapter (PLAN-06). Registered under id
#' `"acirl_field_xlsx"` by [register_builtin_adapters()] in `R/zzz.R`.
#'
#' @return a list with elements `id`, `version`, `match`, `parse`.
#' @keywords internal
#' @noRd
acirl_field_xlsx_adapter <- function() {
  version <- "1.0"
  list(
    id = "acirl_field_xlsx",
    version = version,
    match = function(file_meta) .st_acirl_match(file_meta),
    parse = function(path, file_meta) .st_acirl_parse(path, file_meta, version)
  )
}

# --- R-6.1 match() -----------------------------------------------------

# `format` when ext in {xls, xlsx} AND a sheet name matches `(?i)front` AND
# some sheet has a `Units` marker cell in its first ~15 rows (cheap readxl
# range read); `no` otherwise.
.st_acirl_match <- function(fm) {
  if (!isTRUE(fm$ext %in% c("xls", "xlsx"))) {
    return("no")
  }

  sheet_names <- fm$sheet_names
  if (is.null(sheet_names) || length(sheet_names) == 0) {
    return("no")
  }
  if (!any(grepl("front", sheet_names, ignore.case = TRUE))) {
    return("no")
  }

  for (s in sheet_names) {
    if (.st_acirl_sheet_has_units_marker(fm$path, s)) {
      return("format")
    }
  }

  # Second arm (R-6.1, added 2026-08-01 with A73). A `Units` marker only ever
  # occurs on a WATER sheet, so the 6 real dust-only workbooks
  # ("2400-7286-10-02 Dust Blaxland WMF.xls" and siblings) all measured
  # match() == "no" - the adapter never claimed them, and reversing A10 alone
  # would have recovered no dust from them at all.
  for (s in sheet_names[grepl("dust results", sheet_names, ignore.case = TRUE)]) {
    if (.st_acirl_sheet_has_dust_marker(fm$path, s)) {
      return("format")
    }
  }
  "no"
}

# Dust fingerprint: a "Dust Results" sheet carrying both the gauge-number and
# insoluble-solids headers. Present on all 50 real dust-results sheets.
.st_acirl_sheet_has_dust_marker <- function(path, sheet) {
  df <- tryCatch(
    suppressMessages(readxl::read_excel(
      path, sheet = sheet, col_names = FALSE, col_types = "text", n_max = 20
    )),
    error = function(e) NULL
  )
  if (is.null(df) || nrow(df) == 0) {
    return(FALSE)
  }
  flat <- trimws(unlist(df))
  any(grepl("^GAUGE NO", flat, ignore.case = TRUE), na.rm = TRUE) &&
    any(grepl("^INSOLUBLE SOLID", flat, ignore.case = TRUE), na.rm = TRUE)
}

# Cheap check: does this sheet have a cell reading exactly "Units" (after
# trimming) anywhere in its first 15 rows?
.st_acirl_sheet_has_units_marker <- function(path, sheet) {
  df <- tryCatch(
    suppressMessages(readxl::read_excel(
      path, sheet = sheet, col_names = FALSE, col_types = "text", n_max = 15
    )),
    error = function(e) NULL
  )
  if (is.null(df) || nrow(df) == 0) {
    return(FALSE)
  }
  any(vapply(
    df,
    function(col) any(grepl("^Units$", trimws(col)), na.rm = TRUE),
    logical(1)
  ))
}

# --- parse() dispatch + crash containment -------------------------------

.st_acirl_parse <- function(path, fm, version) {
  tryCatch(
    .st_acirl_parse_impl(path, fm, version),
    error = function(e) {
      if (inherits(e, "sampletidy_parse_error")) {
        stop(e)
      }
      cli::cli_abort(
        "Failed to parse {.path {path}} as an ACIRL field workbook: {conditionMessage(e)}",
        class = "sampletidy_parse_error",
        parent = e
      )
    }
  )
}

.st_acirl_parse_impl <- function(path, fm, version) {
  sheet_names <- fm$sheet_names
  if (is.null(sheet_names)) {
    sheet_names <- readxl::excel_sheets(path)
  }

  is_front <- grepl("front", sheet_names, ignore.case = TRUE)
  is_dust <- grepl("dust", sheet_names, ignore.case = TRUE)
  is_method <- grepl("method", sheet_names, ignore.case = TRUE)
  water_idx <- which(!is_front & !is_dust & !is_method)

  warnings_vec <- character(0)
  skipped_list <- list()

  # --- front page -> header ---------------------------------------------
  header <- list(
    report_no = NA_character_, sampled_by = NA_character_,
    sample_date = NA_character_
  )
  front_idx <- which(is_front)
  if (length(front_idx) > 0) {
    front_grid <- suppressMessages(readxl::read_excel(
      path, sheet = sheet_names[[front_idx[[1]]]], col_names = FALSE, col_types = "text"
    ))
    fp <- .st_acirl_parse_front_page(front_grid)
    header <- fp$header
    warnings_vec <- c(warnings_vec, fp$warnings)
  } else {
    warnings_vec <- c(warnings_vec, sprintf(
      "%s: no front-page sheet found (name matching 'front'); header fields default to NA.",
      fm$filename
    ))
  }

  # --- water sheets -> results + samples ----------------------------------
  field_analytes <- st_config("field_analytes")
  transcription_labels <- st_config("acirl_transcription_labels")
  adapter_tag <- paste0("acirl_field_xlsx/", version)

  results_rows <- list()
  samples_rows <- list()
  # R-6.3b/R-6.5: carried on `report`, NOT on ir_results, whose columns are
  # pinned by the IR contract. `report` reaches `assemble_events(parsed)`,
  # which is the first stage that can see the rest of the batch. Written for
  # A75's value comparison; A79 replaced that with supersession at reconcile
  # and A80 consumes the citation for filing, but the routing is the same -
  # the adapter cannot act on any of it.
  als_candidate_rows <- list()
  alias_rows_all <- list()
  als_work_orders <- character(0)

  # --- dust sheets -> results + samples (R-6.4, A73/A77) -----------------
  # A73 reversed A10: dust IS parsed. Results and Observations carry disjoint
  # information and are joined on (gauge, month-block) - see R-6.4a. Dust is
  # exempt from any ALS linkage: it is ACIRL's own AS3580.10.1 analysis.
  dust_res_idx <- which(is_dust & grepl("result", sheet_names, ignore.case = TRUE))
  dust_obs_idx <- which(is_dust & !grepl("result|method", sheet_names, ignore.case = TRUE))

  dust_rows <- list()
  for (idx in dust_res_idx) {
    dr <- .st_acirl_parse_dust_results(path, sheet_names[[idx]])
    if (length(dr$skipped) > 0) skipped_list <- c(skipped_list, dr$skipped)
    warnings_vec <- c(warnings_vec, dr$warnings)
    dust_rows <- c(dust_rows, dr$rows)
  }
  obs_rows <- list()
  for (idx in dust_obs_idx) {
    do_ <- .st_acirl_parse_dust_observations(path, sheet_names[[idx]])
    if (length(do_$skipped) > 0) skipped_list <- c(skipped_list, do_$skipped)
    warnings_vec <- c(warnings_vec, do_$warnings)
    obs_rows <- c(obs_rows, do_$rows)
  }
  obs_by_key <- list()
  for (o in obs_rows) obs_by_key[[paste(o$gauge, o$block, sep = "\r")]] <- o

  serial_date <- function(x) {
    n <- suppressWarnings(as.numeric(x))
    if (is.na(n)) return(NA_character_)
    format(as.Date(n, origin = "1899-12-30"), "%d/%m/%Y")
  }

  dust_samples <- list()
  for (d in dust_rows) {
    key <- paste(d$gauge, d$block, sep = "\r")
    o <- obs_by_key[[key]]

    # A77: `Month` (Results) and `EXPOSURE DATE` (Observations) are cross-checked
    # and NEITHER is authoritative - they disagree on 8 of 64 real gauge-blocks.
    # A disagreement is recorded and routed to review; it never silently picks one.
    month_d <- serial_date(d$month_serial)
    exp_d   <- if (is.null(o)) NA_character_ else serial_date(o$exposure_serial)
    if (!is.na(month_d) && !is.na(exp_d) && !identical(month_d, exp_d)) {
      skipped_list[[length(skipped_list) + 1]] <- tibble::tibble(
        source_ref = d$source_ref, reason = "dust_exposure_date_conflict"
      )
      warnings_vec <- c(warnings_vec, sprintf(
        "%s: gauge %s block %d - Results Month (%s) and Observations EXPOSURE DATE (%s) disagree; routed to review (A77).",
        fm$filename, d$gauge, d$block, month_d, exp_d))
    }
    # Exposure start is the sampling date where we have it; `Month` is the
    # fallback for a workbook with no Observations sheet.
    samp_date <- if (!is.na(exp_d)) exp_d else month_d
    lab_id <- sprintf("%s!b%d", d$gauge, d$block)

    pv <- parse_value(d$value_raw)
    results_rows[[length(results_rows) + 1]] <- tibble::tibble(
      source_hash = fm$hash, source_ref = d$source_ref,
      work_order = header$report_no, revision = 0L, org = "ACIRL",
      adapter = adapter_tag, lab_sample_id = lab_id, sample_type = "Normal",
      feature_raw = d$gauge, analyte_raw = d$analyte, cas_number = NA_character_,
      method_raw = NA_character_, total_or_filtered = NA_character_,
      units_raw = "g/m2/month", value_raw = d$value_raw,
      value_num = pv$value_num, value_chr = NA_character_,
      below_detection = grepl("^<", d$value_raw),
      rl = NA_real_, lab_qualifier = NA_character_,
      analysed_date = as.Date(NA_character_), comments = NA_character_, confidence = 1
    )
    if (is.null(dust_samples[[lab_id]])) {
      dust_samples[[lab_id]] <- tibble::tibble(
        source_hash = fm$hash, source_ref = d$source_ref,
        work_order = header$report_no, org = "ACIRL", adapter = adapter_tag,
        lab_sample_id = lab_id, feature_raw = d$gauge,
        sample_datetime_raw = samp_date, sample_type = "Normal",
        parent_sample = NA_character_, matrix_raw = "Dust",
        sampler = header$sampled_by,
        comments = if (is.null(o)) NA_character_ else o$observation,
        confidence = 1
      )
    }
    # R-6.7 extends to dust: `Other Sample Id` is a site name, not an analyte.
    if (!is.null(d$other_id) && !is.na(d$other_id) && nzchar(d$other_id)) {
      alias_rows_all[[length(alias_rows_all) + 1]] <- tibble::tibble(
        source_ref = d$source_ref, feature_raw = d$gauge,
        label = "Other Sample Id", alias = d$other_id
      )
    }
  }
  # The observation text is a QUALITATIVE RESULT as well as a sample comment
  # (A73): `ANALYSIS OBSERVATIONS` is a registered ACIRL lab_method against the
  # `Appearance` analyte, so it must resolve like any other analyte_raw.
  for (o in obs_rows) {
    if (is.na(o$observation) || !nzchar(o$observation)) next
    lab_id <- sprintf("%s!b%d", o$gauge, o$block)
    results_rows[[length(results_rows) + 1]] <- tibble::tibble(
      source_hash = fm$hash, source_ref = o$source_ref,
      work_order = header$report_no, revision = 0L, org = "ACIRL",
      adapter = adapter_tag, lab_sample_id = lab_id, sample_type = "Normal",
      feature_raw = o$gauge, analyte_raw = "ANALYSIS OBSERVATIONS",
      cas_number = NA_character_, method_raw = NA_character_,
      total_or_filtered = NA_character_, units_raw = NA_character_,
      value_raw = o$observation, value_num = NA_real_,
      value_chr = o$observation, below_detection = FALSE,
      rl = NA_real_, lab_qualifier = NA_character_,
      analysed_date = as.Date(NA_character_), comments = NA_character_, confidence = 1
    )
  }
  samples_rows <- c(samples_rows, unname(dust_samples))

  for (idx in water_idx) {
    sheet_name <- sheet_names[[idx]]
    ws <- .st_acirl_parse_water_sheet(path, sheet_name, field_analytes,
                                      transcription_labels)
    warnings_vec <- c(warnings_vec, ws$warnings)
    if (length(ws$skipped) > 0) {
      skipped_list <- c(skipped_list, ws$skipped)
    }
    if (length(ws$als_candidates) > 0) {
      als_candidate_rows <- c(als_candidate_rows, ws$als_candidates)
    }
    if (length(ws$feature_aliases) > 0) {
      alias_rows_all <- c(alias_rows_all, ws$feature_aliases)
    }
    als_work_orders <- unique(c(als_work_orders, ws$als_work_orders))

    for (rr in ws$results) {
      results_rows[[length(results_rows) + 1]] <- tibble::tibble(
        source_hash = fm$hash,
        source_ref = rr$source_ref,
        work_order = header$report_no,
        revision = 0L,
        org = "ACIRL",
        adapter = adapter_tag,
        lab_sample_id = rr$lab_sample_id,
        sample_type = "Normal",
        feature_raw = rr$feature_raw,
        analyte_raw = rr$analyte_raw,
        cas_number = NA_character_,
        method_raw = NA_character_,
        total_or_filtered = NA_character_,
        units_raw = rr$units_raw,
        value_raw = rr$value_raw,
        value_num = rr$value_num,
        value_chr = rr$value_chr,
        below_detection = rr$below_detection,
        rl = NA_real_,
        lab_qualifier = NA_character_,
        analysed_date = as.Date(NA_character_),
        comments = NA_character_,
        confidence = 1
      )
    }

    for (sr in ws$samples) {
      samples_rows[[length(samples_rows) + 1]] <- tibble::tibble(
        source_hash = fm$hash,
        source_ref = sr$source_ref,
        work_order = header$report_no,
        org = "ACIRL",
        adapter = adapter_tag,
        lab_sample_id = sr$lab_sample_id,
        feature_raw = sr$feature_raw,
        sample_datetime_raw = sr$sample_datetime_raw,
        sample_type = "Normal",
        parent_sample = NA_character_,
        matrix_raw = "Water",
        sampler = header$sampled_by,
        comments = sr$comments,
        confidence = 1
      )
    }
  }

  results <- if (length(results_rows) == 0) {
    ir_results()
  } else {
    do.call(ir_results, as.list(dplyr::bind_rows(results_rows)))
  }
  samples <- if (length(samples_rows) == 0) {
    ir_samples()
  } else {
    do.call(ir_samples, as.list(dplyr::bind_rows(samples_rows)))
  }
  skipped <- if (length(skipped_list) == 0) {
    tibble::tibble(source_ref = character(0), reason = character(0))
  } else {
    dplyr::bind_rows(skipped_list)
  }

  feature_aliases <- if (length(alias_rows_all) == 0) {
    tibble::tibble(source_ref = character(0), feature_raw = character(0),
                   label = character(0), alias = character(0))
  } else {
    dplyr::distinct(dplyr::bind_rows(alias_rows_all))
  }

  als_candidates <- if (length(als_candidate_rows) == 0) {
    tibble::tibble(
      source_ref = character(0), feature_raw = character(0),
      analyte_raw = character(0), units_raw = character(0),
      value_raw = character(0), transcription_label = logical(0)
    )
  } else {
    dplyr::bind_rows(als_candidate_rows)
  }

  list(
    results = results,
    samples = samples,
    report = list(
      n_rows = nrow(results) + nrow(samples),
      n_by_sample_type = table(results$sample_type),
      skipped = skipped,
      header = header,
      warnings = warnings_vec,
      # R-6.5: exposed for PLAN-09. The adapter takes NO action on this - it
      # cannot see which work orders are held. Written for A74's gate, which
      # A79 withdrew; A80 now files the cited order as a CHILD project of the
      # ACIRL report number, so the field is still load-bearing.
      als_work_orders = als_work_orders,
      # R-6.5b: how many sheets this file treated as WATER sheets. Needed
      # because an empty `als_work_orders` is ambiguous on its own: it means
      # "dust-only workbook" for 5 real files and "water workbook that cites no
      # ALS report at all" for 1 (`2400-7483-01 May 2025 Lawson Landfill.xls`,
      # whose ALS row literally reads `ES` with no number). Both import under
      # A79, but they are not the same thing to A80 - the first correctly has
      # no ALS child project, the second has water data whose lab report we
      # cannot name. Keyed on sheets ATTEMPTED, not sheets that yielded rows,
      # so a parser bug reads as "water we failed to parse", not "never had
      # any".
      n_water_sheets = length(water_idx),
      # R-6.3b: ALS-looking rows kept WITH their values. Written for A75's
      # value comparison, which A79 replaced. They are STILL not results: A79
      # imports them as transcriptions, but only once each label has an ACIRL
      # `lab_method` carrying an analyte, and 215 of the 218 labels have no
      # ACIRL method at all today (measured). Until the dangling-method
      # confirmation pass runs, promoting them here would import ~38,000 rows
      # that R-8.9's supersession cannot match and so cannot ever supersede -
      # silent duplicates, the failure mode A79 inverts. The promotion belongs
      # with that pass, not here.
      als_candidates = als_candidates,
      # R-6.7: point-code -> human-name evidence lifted off the site-metadata
      # rows, so recognising them as metadata costs no information. Nothing
      # consumes this yet; the feature-alias subsystem is its home.
      feature_aliases = feature_aliases
    )
  )
}

# --- R-6.2 front page ----------------------------------------------------

# Extracts REPORT NO: / SAMPLED BY: / SAMPLE DATE:, each sitting one cell to
# the right of its key cell (`vector_from_key(direction = "right")`).
# Missing keys and ambiguous (duplicate) keys are both tolerated (parse
# continues; a warning is recorded, value NA) rather than aborting -
# `vector_from_key()` itself aborts on zero *or* multiple matches, so
# presence/uniqueness is checked first via `str_which_df(multiple_matches =
# TRUE)`.
.st_acirl_parse_front_page <- function(front_grid) {
  warnings_vec <- character(0)

  get_key <- function(pattern, label) {
    hits <- str_which_df(front_grid, pattern, ignore_case = TRUE, multiple_matches = TRUE)
    if (nrow(hits) == 0) {
      warnings_vec <<- c(warnings_vec, sprintf(
        "Front page: '%s' key not found.", label
      ))
      return(NA_character_)
    }
    if (nrow(hits) > 1) {
      warnings_vec <<- c(warnings_vec, sprintf(
        "Front page: '%s' key found in multiple cells; ambiguous, skipped.", label
      ))
      return(NA_character_)
    }
    vals <- vector_from_key(front_grid, pattern, direction = "right", ignore_case = TRUE)
    if (length(vals) == 0) NA_character_ else stringr::str_squish(vals[[1]])
  }

  report_no <- get_key("^REPORT NO:$", "REPORT NO:")
  sampled_by_raw <- get_key("^SAMPLED BY:$", "SAMPLED BY:")
  sample_date <- get_key("^SAMPLE DATE:$", "SAMPLE DATE:")

  sampled_by <- if (is.na(sampled_by_raw)) {
    NA_character_
  } else {
    stringr::str_squish(sub("&.*$", "", sampled_by_raw))
  }

  list(
    header = list(
      report_no = report_no, sampled_by = sampled_by, sample_date = sample_date
    ),
    warnings = warnings_vec
  )
}

# --- R-6.3a water sheets (real geometry) ------------------------------------

# Parses one water sheet into raw (pre-IR) results/samples row lists, ALS
# candidates, skipped rows and warnings.
#
# GEOMETRY (PLAN-06 R-6.3a; measured over 986 real water sheets, 640 of which
# carry a `Site Name` row - every rule below held on every one of them):
#
#   the `Site Name` row is the HEADER row and its column is the LABEL column
#   units_col         == site_col + 1                        640/640
#   first_feature_col == units_col + 1                       640/640
#   date-label column == site_col                            640/640
#   date_row          == site_row - 1  (ABOVE the site row)  640/640
#
# The previous implementation took the header from the `Units` marker row and
# the labels from a hardcoded column 1. Neither holds in any real workbook: the
# `Units` marker sits 3-4 rows ABOVE the site row on its own, and labels sit in
# the site column. That defect extracted zero rows from all 147 real ACIRL
# workbooks while passing every test. `Units` is now used only as the match()
# fingerprint (R-6.1), never to locate the block.
#
# The date row is searched ABOVE the site row first and below only as a
# fallback, so the older fixture layout (date below) still parses.
#
# There is NO block terminator any more. Rows below the block are no longer
# guessed at by a regex: every labelled row is classified - a row with no
# values anywhere is a heading and is dropped, `----` is "not analysed", a row
# on the field allowlist is a field reading, and anything else is an
# `als_candidate` recorded in `report$als_candidates` WITH ITS VALUES. Dropping
# those rows here (the old `lab_data_dropped` behaviour) destroyed the values
# outright; keeping them is what lets A79 import them as transcriptions once
# their labels have analytes.
.st_acirl_parse_water_sheet <- function(path, sheet_name, field_analytes,
                                        transcription_labels = character(0)) {
  empty_out <- function(skipped = list(), warnings = character(0)) {
    list(results = list(), samples = list(), skipped = skipped,
         warnings = warnings, als_candidates = list(),
         feature_aliases = list(), als_work_orders = character(0))
  }

  grid <- tryCatch(
    suppressMessages(readxl::read_excel(
      path, sheet = sheet_name, col_names = FALSE, col_types = "text"
    )),
    error = function(e) NULL
  )
  if (is.null(grid) || nrow(grid) == 0) {
    return(empty_out())
  }

  mat <- as.matrix(grid)
  dimnames(mat) <- NULL # readxl's default col_names=FALSE colnames ("...1", ...)
  # would otherwise attach as a `names` attribute on every single-cell
  # extraction below, leaking into the IR tibbles' columns.
  n_row <- nrow(mat)
  n_col <- ncol(mat)

  cell <- function(r, c) {
    if (r < 1 || r > n_row || c < 1 || c > n_col) return(NA_character_)
    v <- mat[r, c]
    if (is.na(v)) NA_character_ else trimws(v)
  }
  nonempty <- function(x) !is.na(x) && nzchar(x)

  # --- anchor: the `Site Name` row -----------------------------------------
  site_hits <- which(
    matrix(grepl("^site\\s*name$", trimws(mat), ignore.case = TRUE), nrow = n_row),
    arr.ind = TRUE
  )
  if (nrow(site_hits) == 0) {
    warn <- sprintf(
      "Sheet '%s': no 'Site Name' header row found; sheet skipped.", sheet_name
    )
    return(empty_out(
      skipped = list(tibble::tibble(source_ref = sheet_name, reason = "no_site_row")),
      warnings = warn
    ))
  }
  header_row <- as.integer(site_hits[1, 1])
  label_col <- as.integer(site_hits[1, 2])
  units_col <- label_col + 1L

  # --- sample columns + feature names, from the Site Name row ---------------
  sample_cols <- integer(0)
  feature_by_col <- list()
  if (n_col > units_col) {
    for (j in (units_col + 1L):n_col) {
      v <- cell(header_row, j)
      if (nonempty(v)) {
        sample_cols <- c(sample_cols, j)
        feature_by_col[[as.character(j)]] <- stringr::str_squish(v)
      }
    }
  }
  if (length(sample_cols) == 0) {
    warn <- sprintf("Sheet '%s': no sample columns found in the header row; sheet skipped.", sheet_name)
    return(empty_out(
      skipped = list(tibble::tibble(source_ref = sheet_name, reason = "no_sample_columns")),
      warnings = warn
    ))
  }

  # --- ALS cross-reference (R-6.5): exposed, never acted on here -------------
  # EVERY matching label row is scanned, not just the first. A sheet may carry
  # more than one `ALS ... Report No` row - measured: `2400-7223-12-01 2022
  # December Quarterly Katoomba WMF.xls` has `ALS Lithogw Report No` (holding
  # the ACIRL report number, no ES at all) immediately ABOVE `ALS Sydney Report
  # No.` (holding ES2246297). Breaking on the first match read the Lithgow row,
  # found no `ES#######`, and reported the file as citing NOTHING - which under
  # the A74 gate is the difference between importing 57 rows and quarantining
  # them. Scanning every match costs nothing: a row with no ES pattern
  # contributes no work orders.
  als_work_orders <- character(0)
  for (r in seq_len(n_row)) {
    v <- cell(r, label_col)
    if (!nonempty(v) || !grepl("ALS.*report\\s*no", v, ignore.case = TRUE)) next
    for (j in seq_len(n_col)) {
      if (j == label_col) next
      w <- cell(r, j)
      if (nonempty(w)) {
        als_work_orders <- c(als_work_orders,
                             unlist(regmatches(w, gregexpr("ES[0-9]{7}", w))))
      }
    }
  }
  als_work_orders <- unique(als_work_orders)

  # --- date row: prefer ABOVE the header row, fall back to below -------------
  date_candidates <- integer(0)
  for (r in seq_len(n_row)) {
    v <- cell(r, label_col)
    if (nonempty(v) && grepl("date", v, ignore.case = TRUE)) {
      date_candidates <- c(date_candidates, r)
    }
  }
  above <- date_candidates[date_candidates < header_row]
  below <- date_candidates[date_candidates > header_row]
  date_row <- if (length(above)) max(above) else if (length(below)) min(below) else NA_integer_
  if (is.na(date_row)) {
    warn <- sprintf("Sheet '%s': no Date row found; sheet skipped.", sheet_name)
    return(empty_out(
      skipped = list(tibble::tibble(source_ref = sheet_name, reason = "no_date_row")),
      warnings = warn
    ))
  }

  # Excel-serial dates per sample column, filled down left-to-right.
  date_serial_by_col <- list()
  last_val <- NA_character_
  for (j in sample_cols) {
    v <- cell(date_row, j)
    if (nonempty(v)) last_val <- v
    date_serial_by_col[[as.character(j)]] <- last_val
  }
  sample_datetime_by_col <- lapply(date_serial_by_col, function(raw) {
    if (is.na(raw)) {
      return(NA_character_)
    }
    num <- suppressWarnings(as.numeric(raw))
    if (is.na(num)) NA_character_ else format(excel_date(num), "%d/%m/%Y")
  })

  # --- parameter rows -------------------------------------------------------
  results_rows <- list()
  skipped_rows <- list()
  als_candidates <- list()
  comments_by_col <- list()
  obs_by_col <- list()
  warnings_local <- character(0)

  alias_rows <- list()
  # R-6.7: the three measured site-metadata labels. Pinned here rather than in
  # `st_config()` because, unlike the field allowlist, this is not a policy
  # choice - it is a fact about the sheet layout, and a site name is never an
  # analyte under any ruling.
  meta_norm <- c("OTHER SAMPLE ID", "OTHER SITE NAME", "OTHER SITE ID")
  allowed_norm <- toupper(stringr::str_squish(field_analytes))
  trans_norm <- toupper(stringr::str_squish(transcription_labels))

  for (r in seq_len(n_row)) {
    if (r <= header_row || r == date_row) next
    label_raw <- cell(r, label_col)
    if (!nonempty(label_raw)) next
    label <- label_raw

    # Observation / comments rows attach to the sample, not to results. The
    # real labels are not bare "Comments" - measured across the corpus:
    # "General Comments/ Observations" (102), "Observations / Comments" (60),
    # "Flow Observation / Appearance" (49). A76 converts these to qualitative
    # `Stage`/`Appearance` analysis rows; that split needs a value vocabulary
    # ("Low flow Clear" -> Stage + Appearance) and is deliberately NOT done
    # here - see PLAN-06.
    if (.st_acirl_is_comment_label(label)) {
      for (j in sample_cols) {
        v <- cell(r, j)
        if (!nonempty(v)) next
        key <- as.character(j)
        txt <- stringr::str_squish(v)
        prev <- comments_by_col[[key]]
        # The RAW text is preserved on the sample regardless of the split
        # below. It is the only home for the observations that describe no
        # water at all ("could not locate", "no access", "decommissioned"),
        # which map to neither analyte.
        comments_by_col[[key]] <- if (is.null(prev)) txt else paste(prev, txt, sep = "; ")

        # A76: an observation is a QUALITATIVE RESULT, not merely a note.
        # Split it into at most one `Stage` and one `Appearance` value.
        # First non-NA wins per (column, analyte): a sheet carrying both
        # "Flow Observation / Appearance" and "Observations / Comments" would
        # otherwise emit the same field reading twice (Robin, 2026-08-01).
        sp <- .st_acirl_split_observation(txt)
        cur <- obs_by_col[[key]]
        if (is.null(cur)) {
          cur <- list(
            stage = NA_character_, stage_ref = NA_character_, stage_raw = NA_character_,
            appearance = NA_character_, appearance_ref = NA_character_,
            appearance_raw = NA_character_
          )
        }
        if (is.na(cur$stage) && !is.na(sp$stage)) {
          cur$stage <- sp$stage
          cur$stage_raw <- txt
          cur$stage_ref <- sprintf("%s!r%dc%d", sheet_name, r, j)
        }
        if (is.na(cur$appearance) && !is.na(sp$appearance)) {
          cur$appearance <- sp$appearance
          cur$appearance_raw <- txt
          cur$appearance_ref <- sprintf("%s!r%dc%d", sheet_name, r, j)
        }
        obs_by_col[[key]] <- cur
      }
      next
    }

    analyte_raw_val <- normalise_lab_text(label)
    analyte_norm <- toupper(stringr::str_squish(analyte_raw_val))

    # R-6.7: SITE-METADATA rows are not analytes. A water sheet may carry the
    # sampling point's alternative name as an ordinary label row - values like
    # "BORE 2", "Cripple Creek", "EFFLUENT" against the point code in the
    # header. Measured over all 154 claimed workbooks there are exactly three
    # such labels, and their values are 100% non-numeric:
    #
    #     Other Sample Id   2604 rows, 97 files
    #     Other Site Name     26 rows
    #     Other Site ID        5 rows
    #
    # Before this they took the `als_candidate` path, and would have carried
    # ~2,635 rows of pure noise into the transcription population - 21% of the
    # entire no-twin population. They are not dropped either: the point-code -> name
    # mapping is real evidence for the feature-alias subsystem, so it is carried
    # on `report$feature_aliases` rather than thrown away.
    if (analyte_norm %in% meta_norm) {
      for (j in sample_cols) {
        v <- cell(r, j)
        if (!nonempty(v)) next
        alias_rows[[length(alias_rows) + 1]] <- tibble::tibble(
          source_ref = sprintf("%s!r%dc%d", sheet_name, r, j),
          feature_raw = feature_by_col[[as.character(j)]],
          label = analyte_raw_val,
          alias = stringr::str_squish(v)
        )
      }
      skipped_rows[[length(skipped_rows) + 1]] <- tibble::tibble(
        source_ref = sprintf("%s!r%d", sheet_name, r), reason = "site_metadata_label"
      )
      next
    }
    # The TSS pair: a label whose NAME is indistinguishable from the ALS
    # analyte's - `Total Suspended Solids` is both the ACIRL sheet label and the
    # ALS analyte name, so no name test can separate a reading from a copy.
    #
    # SETTLED 2026-08-02 by measurement, not by the name: they are copies. 284
    # of 678 carry ALS's own `<5` reporting limit, and 355 of the 362 values
    # comparable against an ALS TSS row are identical (the 7 that differ are
    # permutations of ALS's numbers - copy errors). ACIRL's two `field` TSS
    # lab_methods, which claimed otherwise and carried zero analyses, were
    # deleted from the live registry the same day. So this is no longer a
    # deferred decision: the label takes the ALS-candidate path because it IS a
    # transcription, and R-8.9 supersedes it once its analyte is known.
    is_transcription_label <- analyte_norm %in% trans_norm
    is_allowed <- !is_transcription_label && analyte_norm %in% allowed_norm
    units_cell <- cell(r, units_col)

    # A row with no value in ANY sample column is a section heading
    # ("Dissolved Major Cations", "Dissolved Metals by ICP-MS"), not an
    # analyte. Dropped silently: no result, no ALS candidate, no review item.
    if (!any(vapply(sample_cols, function(j) nonempty(cell(r, j)), logical(1)))) {
      skipped_rows[[length(skipped_rows) + 1]] <- tibble::tibble(
        source_ref = sprintf("%s!r%d", sheet_name, r), reason = "heading"
      )
      next
    }

    for (j in sample_cols) {
      value_raw_cell <- cell(r, j)
      source_ref <- sprintf("%s!r%dc%d", sheet_name, r, j)

      # "----" is the sheet's "not analysed" placeholder, not a value.
      if (nonempty(value_raw_cell) && grepl("^-{2,}$", value_raw_cell)) {
        skipped_rows[[length(skipped_rows) + 1]] <- tibble::tibble(
          source_ref = source_ref, reason = "not_analysed"
        )
        next
      }

      if (!is_allowed) {
        # Kept WITH its value - the adapter sees one file and no database, so
        # it can neither resolve the analyte nor find the ALS twin. Both are
        # R-8.9's job at reconcile.
        if (nonempty(value_raw_cell)) {
          als_candidates[[length(als_candidates) + 1]] <- tibble::tibble(
            source_ref = source_ref,
            feature_raw = feature_by_col[[as.character(j)]],
            analyte_raw = analyte_raw_val,
            units_raw = .st_acirl_repair_units(analyte_raw_val, units_cell),
            value_raw = value_raw_cell,
            transcription_label = is_transcription_label
          )
        }
        skipped_rows[[length(skipped_rows) + 1]] <- tibble::tibble(
          source_ref = source_ref,
          reason = if (is_transcription_label) "transcription_label" else "lab_data_dropped"
        )
        next
      }

      pv <- parse_value(value_raw_cell)
      if (!is.na(pv$skip_reason)) {
        skipped_rows[[length(skipped_rows) + 1]] <- tibble::tibble(
          source_ref = source_ref, reason = pv$skip_reason
        )
        next
      }

      results_rows[[length(results_rows) + 1]] <- list(
        source_ref = source_ref,
        # R-11.15: synthetic per-column lab_sample_id, keyed on sheet name
        # + column index (both stable across a re-parse of the same file,
        # distinct per sample column) - ties this result to the exact
        # sample column it came from, so `.st_join_samples_onto_results()`
        # (assemble.R) takes the exact-match branch instead of the
        # feature-name-only fallback that conflates sibling visits.
        lab_sample_id = sprintf("%s!c%d", sheet_name, j),
        feature_raw = feature_by_col[[as.character(j)]],
        analyte_raw = analyte_raw_val,
        units_raw = .st_acirl_repair_units(analyte_raw_val, units_cell),
        value_raw = value_raw_cell,
        value_num = pv$value_num,
        value_chr = pv$value_chr,
        below_detection = grepl("^<", value_raw_cell)
      )
    }
  }

  # A76: emit the split observations. `analyte_raw` is the registered
  # `lab_method.name` ("Flow observation" -> analyte `Stage`, "Comments" ->
  # analyte `Appearance`), because reconcile resolves an analyte by matching
  # `lab_method.name` against `analyte_raw` - see `.rc_resolve_one_analyte()`.
  # Both are qualitative: `value_chr` carries the canonical term, `value_num`
  # is NA, and `value_raw` keeps the whole original observation so the split
  # stays auditable from the row itself.
  for (key in names(obs_by_col)) {
    o <- obs_by_col[[key]]
    for (part in c("stage", "appearance")) {
      val <- o[[part]]
      if (is.na(val)) next
      results_rows[[length(results_rows) + 1]] <- list(
        source_ref = o[[paste0(part, "_ref")]],
        lab_sample_id = sprintf("%s!c%s", sheet_name, key),
        feature_raw = feature_by_col[[key]],
        analyte_raw = if (part == "stage") "Flow observation" else "Comments",
        units_raw = NA_character_,
        value_raw = o[[paste0(part, "_raw")]],
        value_num = NA_real_,
        value_chr = val,
        below_detection = FALSE
      )
    }
  }

  samples_rows <- lapply(sample_cols, function(j) {
    key <- as.character(j)
    # R-11.15: same synthetic id as the results rows derived from this
    # column (source_ref happens to share the identical "<sheet>!c<col>"
    # format already, so lab_sample_id is set to the same value here).
    list(
      source_ref = sprintf("%s!c%d", sheet_name, j),
      lab_sample_id = sprintf("%s!c%d", sheet_name, j),
      feature_raw = feature_by_col[[key]],
      sample_datetime_raw = sample_datetime_by_col[[key]],
      comments = if (is.null(comments_by_col[[key]])) NA_character_ else comments_by_col[[key]]
    )
  })

  list(
    results = results_rows,
    samples = samples_rows,
    skipped = skipped_rows,
    warnings = warnings_local,
    als_candidates = als_candidates,
    feature_aliases = alias_rows,
    als_work_orders = als_work_orders
  )
}


# ---- R-6.4 dust sheets (A73/A77) ------------------------------------------
#
# GEOMETRY, re-measured 2026-08-01 over all 50 real dust-results sheets and all
# 50 dust-observations sheets (PLAN-06 R-6.4a). The two sheets carry DISJOINT
# information and both are needed:
#
#   Dust Results      GAUGE NO. | Other Sample Id | Month | INSOLUBLE SOLIDS |
#                     *COMBUSTIBLE MATTER | INCOMBUSTIBLE MATTER | Exposure Days
#   Dust Observations GAUGE | EXPOSURE DATE | COLLECTION DATE | DAYS EXPOSED |
#                     ANALYSIS OBSERVATIONS
#
# `Month` and `Exposure Days` appear on Results 50/50 and on Observations 0/50;
# `EXPOSURE DATE`/`COLLECTION DATE` the exact reverse. So **A77's cross-check is
# inherently CROSS-SHEET** and is done in `.st_acirl_parse_impl()`, not here.
#
# Two quirks, both measured, both load-bearing:
#  * INCOMBUSTIBLE MATTER's values sit one column RIGHT of its header on 49 of
#    50 sheets - but on 1 they sit under it. The legacy reader's
#    `coalesce(last, last - 1)` is therefore ported as a COALESCE, never as a
#    constant +1 offset, which would read NA for that one sheet.
#  * quarterly sheets repeat the month-block: gauge rows then one
#    `Exposure Days` row, up to 4 times. `Exposure Days` is NOT a result.

#' Locate a header cell by text, returning `list(row, col)` or NULL.
#' @keywords internal
#' @noRd
.st_acirl_find_header <- function(mat, pattern) {
  hit <- which(matrix(grepl(pattern, mat, ignore.case = TRUE),
                      nrow(mat), ncol(mat)), arr.ind = TRUE)
  if (nrow(hit) == 0) return(NULL)
  list(row = hit[1, 1], col = hit[1, 2])
}

#' Parse one `Dust Results` sheet into per-gauge, per-month rows.
#'
#' @return `list(rows, skipped, warnings)`; `rows` is a list of
#'   `list(gauge, other_id, month_serial, block, analyte, value_raw, source_ref)`.
#' @keywords internal
#' @noRd
.st_acirl_parse_dust_results <- function(path, sheet_name) {
  out <- list(rows = list(), skipped = list(), warnings = character(0))
  grid <- tryCatch(
    suppressMessages(readxl::read_excel(path, sheet = sheet_name,
                                        col_names = FALSE, col_types = "text")),
    error = function(e) NULL
  )
  if (is.null(grid) || nrow(grid) == 0) return(out)
  mat <- as.matrix(grid); dimnames(mat) <- NULL
  cell <- function(r, c) {
    if (r < 1 || c < 1 || r > nrow(mat) || c > ncol(mat)) return(NA_character_)
    v <- mat[r, c]; if (is.na(v)) NA_character_ else stringr::str_squish(v)
  }
  nonempty <- function(x) !is.na(x) && nzchar(x)

  gh <- .st_acirl_find_header(mat, "^GAUGE NO")
  if (is.null(gh)) {
    out$skipped[[1]] <- tibble::tibble(source_ref = sheet_name, reason = "no_gauge_header")
    return(out)
  }
  hdr <- gh$row
  col_of <- function(pat) {
    h <- .st_acirl_find_header(mat, pat)
    if (is.null(h) || h$row != hdr) NA_integer_ else h$col
  }
  c_gauge <- gh$col
  c_other <- col_of("^Other Sample Id")
  c_month <- col_of("^Month$")
  # `*COMBUSTIBLE` must be matched BEFORE `INCOMBUSTIBLE`, and anchored, or
  # "INCOMBUSTIBLE MATTER" satisfies a bare "COMBUSTIBLE" pattern.
  analyte_cols <- list(
    `INSOLUBLE SOLIDS`     = col_of("^INSOLUBLE"),
    `*COMBUSTIBLE MATTER`  = col_of("^[*]?COMBUSTIBLE"),
    `INCOMBUSTIBLE MATTER` = col_of("^INCOMBUSTIBLE")
  )
  if (all(is.na(unlist(analyte_cols)))) {
    out$skipped[[1]] <- tibble::tibble(source_ref = sheet_name, reason = "no_dust_analyte_headers")
    return(out)
  }

  block <- 1L
  for (r in (hdr + 1L):nrow(mat)) {
    lab <- cell(r, c_month)
    # `Exposure Days` closes a month-block and is never a result.
    if (nonempty(lab) && grepl("^Exposure Days", lab, ignore.case = TRUE)) {
      block <- block + 1L
      next
    }
    g <- cell(r, c_gauge)
    if (!nonempty(g) || !grepl("^[A-Z]\\.?D[0-9]", g, ignore.case = TRUE)) next

    for (an in names(analyte_cols)) {
      cc <- analyte_cols[[an]]
      if (is.na(cc)) next
      # COALESCE, not a fixed offset: 49 of 50 sheets carry INCOMBUSTIBLE's
      # values one column right of its header, 1 carries them beneath it.
      v <- cell(r, cc)
      if (!nonempty(v)) v <- cell(r, cc + 1L)
      if (!nonempty(v)) next
      out$rows[[length(out$rows) + 1L]] <- list(
        gauge = g, other_id = if (is.na(c_other)) NA_character_ else cell(r, c_other),
        month_serial = if (is.na(c_month)) NA_character_ else cell(r, c_month),
        block = block, analyte = an, value_raw = v,
        source_ref = sprintf("%s!r%dc%d", sheet_name, r, cc)
      )
    }
  }
  out
}

#' Parse one `Dust Observations` sheet.
#'
#' @return `list(rows, skipped, warnings)`; `rows` is a list of
#'   `list(gauge, block, exposure_serial, collection_serial, days, observation,
#'   source_ref)`.
#' @keywords internal
#' @noRd
.st_acirl_parse_dust_observations <- function(path, sheet_name) {
  out <- list(rows = list(), skipped = list(), warnings = character(0))
  grid <- tryCatch(
    suppressMessages(readxl::read_excel(path, sheet = sheet_name,
                                        col_names = FALSE, col_types = "text")),
    error = function(e) NULL
  )
  if (is.null(grid) || nrow(grid) == 0) return(out)
  mat <- as.matrix(grid); dimnames(mat) <- NULL
  cell <- function(r, c) {
    if (r < 1 || c < 1 || r > nrow(mat) || c > ncol(mat)) return(NA_character_)
    v <- mat[r, c]; if (is.na(v)) NA_character_ else stringr::str_squish(v)
  }
  nonempty <- function(x) !is.na(x) && nzchar(x)

  # The observations sheet labels the column `GAUGE`, not `GAUGE NO.` (0 of 50
  # carry the results-sheet spelling).
  gh <- .st_acirl_find_header(mat, "^GAUGE$")
  if (is.null(gh)) {
    out$skipped[[1]] <- tibble::tibble(source_ref = sheet_name, reason = "no_gauge_header")
    return(out)
  }
  hdr <- gh$row
  col_of <- function(pat) {
    h <- .st_acirl_find_header(mat, pat)
    if (is.null(h) || h$row != hdr) NA_integer_ else h$col
  }
  c_exp  <- col_of("^EXPOSURE *DATE")
  c_coll <- col_of("^COLLECTION *DATE")
  c_days <- col_of("^DAYS *EXPOSED")
  c_obs  <- col_of("^ANALYSIS *OBSERVATION")

  seen <- list()
  for (r in (hdr + 1L):nrow(mat)) {
    g <- cell(r, gh$col)
    if (!nonempty(g) || !grepl("^[A-Z]\\.?D[0-9]", g, ignore.case = TRUE)) next
    # Quarterly sheets repeat each gauge once per month-block, in order, so the
    # nth sighting of a gauge is its nth block - the same ordering the results
    # sheet uses.
    prev <- seen[[g]]
    n <- if (is.null(prev)) 1L else prev + 1L
    seen[[g]] <- n
    out$rows[[length(out$rows) + 1L]] <- list(
      gauge = g, block = n,
      exposure_serial   = if (is.na(c_exp))  NA_character_ else cell(r, c_exp),
      collection_serial = if (is.na(c_coll)) NA_character_ else cell(r, c_coll),
      days              = if (is.na(c_days)) NA_character_ else cell(r, c_days),
      observation       = if (is.na(c_obs))  NA_character_ else cell(r, c_obs),
      source_ref = sprintf("%s!r%d", sheet_name, r)
    )
  }
  out
}

# Observation/comments row labels. Bare "Comments" is the fixture form; the
# real corpus uses longer variants, all of which attach to the sample rather
# than producing a result row.
.st_acirl_is_comment_label <- function(label) {
  grepl("^comments$", label, ignore.case = TRUE) ||
    grepl("comment|observation", label, ignore.case = TRUE)
}

# A76 (Robin, 2026-08-01): an ACIRL observation cell encodes two independent
# qualitative readings in one free-text string - the watercourse STAGE ("Low
# flow", "Pooled", "No discharge") and the water's APPEARANCE ("Clear",
# "Cloudy"). Historically both were written whole into a single `Appearance`
# row; those 291 conflated rows are left alone by ruling, and only new imports
# are split.
#
# The vocabulary below is measured, not invented: 194 distinct observation
# values across the real corpus (`scratchpad/a76_obs_values.rds`) plus the
# existing `Stage`/`Appearance` values already in the database. Misspellings
# are handled by explicit alternation, never by fuzzy matching.
#
# Returns `list(stage, appearance)`, either or both `NA_character_`. A third
# class of observation describes no water at all ("could not locate", "no
# access", "decommissioned", "too dangerous to sample") and correctly yields
# NA for both - the raw text still reaches `sample.comments`.
.st_acirl_split_observation <- function(text) {
  out <- list(stage = NA_character_, appearance = NA_character_)
  if (is.na(text) || !nzchar(text)) return(out)
  x <- tolower(text)
  # The one measured typo that a pattern cannot absorb: "high evel" for
  # "high level". Anchored on word boundaries so real "level" is untouched.
  x <- gsub("\\bevel\\b", "level", x)

  # --- stage ---------------------------------------------------------------
  # Tier 1, magnitude + noun ("Low flow", "Mod level", "High discharge"): the
  # most informative form, so it wins outright over the standalone terms.
  # `\\s*` between the two absorbs the run-together spellings ("lowflow",
  # "modflow"), and the optional separator absorbs "low flow/ clear",
  # "mod-flow", "mod level; clear". The LEADING `\\b` is load-bearing and was
  # added after calibration: without it the "low" inside "flow" matched, so
  # "Clear, flow flow" was read as stage "Low flow". There is deliberately no
  # TRAILING boundary - that would break "lowflow" / "modflow".
  hit <- regmatches(x, regexec(
    "\\b(very\\s*low|low|mod(?:erate)?|high)\\s*[-/,;]?\\s*(flows?|levels?|dis(?:charge)?s?)",
    x, perl = TRUE
  ))[[1]]
  if (length(hit) == 3) {
    magnitude <- switch(
      gsub("\\s+", "", hit[[2]]),
      "verylow" = "Very low", "low" = "Low", "mod" = "Mod",
      "moderate" = "Mod", "high" = "High"
    )
    noun <- if (grepl("^flow", hit[[3]])) {
      "flow"
    } else if (grepl("^level", hit[[3]])) {
      "level"
    } else {
      "discharge"
    }
    out$stage <- paste(magnitude, noun)
  } else {
    # Tier 2, standalone terms. Where several appear ("pipe not running dry",
    # "pooled/ almost dry") the LEFTMOST wins - deterministic, and in the
    # measured corpus the leading term is the one the sampler led with.
    standalone <- c(
      "No discharge" = "no\\s*discharge|non\\s*discharge|no\\s*dis\\b|not\\s*running|no\\s*flows?\\b|not\\s*flowing",
      "Pooled" = "pooled|polled",
      "Dry" = "\\bdry\\b"
    )
    pos <- vapply(standalone, function(p) {
      m <- regexpr(p, x, perl = TRUE)
      if (m[[1]] == -1L) .Machine$integer.max else as.integer(m[[1]])
    }, integer(1))
    if (any(pos < .Machine$integer.max)) {
      out$stage <- names(standalone)[[which.min(pos)]]
    }
  }

  # --- appearance ----------------------------------------------------------
  # Most specific first: "slightly cloudy" must not be read as "cloudy".
  # `sli\\w*ly` covers the measured misspellings (slighlty, slighhtly);
  # `clou\\w*dy` covers clouidy/clouldy; `c\\s*lear` covers the split "c lear".
  if (grepl("sli\\w*ly[ ,/-]*clou\\w*dy", x, perl = TRUE)) {
    out$appearance <- "Slightly cloudy"
  } else if (grepl("clou\\w*dy", x, perl = TRUE)) {
    out$appearance <- "Cloudy"
  } else if (grepl("c\\s*lear|celar", x, perl = TRUE)) {
    out$appearance <- "Clear"
  }

  out
}

# Old reader's unit repairs (WEM.data's tidy_ACIRL_field_data): Temperature
# is always forced to the real degree sign (source sheets sometimes write
# the ASCII "oC" digraph instead); "pH Units" collapses to the dimensionless
# "pH"; a leading-junk-before-mu mojibake remnant is stripped (mojibake
# proper, e.g. the cp1252 U+FFFD variant, is already fixed by
# normalise_lab_text() before this runs).
.st_acirl_repair_units <- function(analyte_raw, units_cell) {
  u <- normalise_lab_text(units_cell)
  u <- if (is.na(u)) NA_character_ else trimws(u)

  dplyr::case_when(
    analyte_raw == "Temperature" ~ "\u00b0C",
    !is.na(u) & u == "pH Units" ~ "pH",
    !is.na(u) & grepl("\u00b5", u, fixed = TRUE) ~ sub("^.+\u00b5", "\u00b5", u),
    TRUE ~ u
  )
}
