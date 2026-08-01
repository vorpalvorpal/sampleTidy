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

  # --- dust sheets: detected, not parsed (A10/R-6.4) ---------------------
  for (idx in which(is_dust)) {
    skipped_list[[length(skipped_list) + 1]] <- tibble::tibble(
      source_ref = sheet_names[[idx]], reason = "dust_sheet_ignored"
    )
  }

  # --- water sheets -> results + samples ----------------------------------
  field_analytes <- st_config("field_analytes")
  adapter_tag <- paste0("acirl_field_xlsx/", version)

  results_rows <- list()
  samples_rows <- list()
  # A75/A74 (R-6.3b, R-6.5): carried on `report`, NOT on ir_results, whose
  # columns are pinned by the IR contract. `report` reaches
  # `assemble_events(parsed)`, which is where the value comparison against the
  # real ALS data can actually run.
  als_candidate_rows <- list()
  als_work_orders <- character(0)

  for (idx in water_idx) {
    sheet_name <- sheet_names[[idx]]
    ws <- .st_acirl_parse_water_sheet(path, sheet_name, field_analytes)
    warnings_vec <- c(warnings_vec, ws$warnings)
    if (length(ws$skipped) > 0) {
      skipped_list <- c(skipped_list, ws$skipped)
    }
    if (length(ws$als_candidates) > 0) {
      als_candidate_rows <- c(als_candidate_rows, ws$als_candidates)
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

  als_candidates <- if (length(als_candidate_rows) == 0) {
    tibble::tibble(
      source_ref = character(0), feature_raw = character(0),
      analyte_raw = character(0), units_raw = character(0),
      value_raw = character(0)
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
      # R-6.5: exposed for PLAN-09's gate (A74). The adapter takes NO action
      # on this - it cannot see which work orders are held.
      als_work_orders = als_work_orders,
      # R-6.3b: ALS-looking rows kept WITH their values for A75's comparison
      # in assemble/reconcile.
      als_candidates = als_candidates
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
# guessed at by a regex: every labelled row is classified (A75) - a row with no
# values anywhere is a heading and is dropped, `----` is "not analysed", a row
# on the field allowlist is a field reading, and anything else is an
# `als_candidate` recorded in `report$als_candidates` WITH ITS VALUES so the
# A75 value comparison can run later in assemble/reconcile. Dropping those rows
# here (the old `lab_data_dropped` behaviour) destroyed the very values that
# comparison needs.
.st_acirl_parse_water_sheet <- function(path, sheet_name, field_analytes) {
  empty_out <- function(skipped = list(), warnings = character(0)) {
    list(results = list(), samples = list(), skipped = skipped,
         warnings = warnings, als_candidates = list(),
         als_work_orders = character(0))
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
  als_work_orders <- character(0)
  als_row <- NA_integer_
  for (r in seq_len(n_row)) {
    v <- cell(r, label_col)
    if (nonempty(v) && grepl("ALS.*report\\s*no", v, ignore.case = TRUE)) {
      als_row <- r
      break
    }
  }
  if (!is.na(als_row)) {
    for (j in seq_len(n_col)) {
      if (j == label_col) next
      v <- cell(als_row, j)
      if (nonempty(v)) {
        als_work_orders <- c(als_work_orders,
                             unlist(regmatches(v, gregexpr("ES[0-9]{7}", v))))
      }
    }
    als_work_orders <- unique(als_work_orders)
  }

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
  warnings_local <- character(0)

  allowed_norm <- toupper(stringr::str_squish(field_analytes))

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
        if (nonempty(v)) {
          key <- as.character(j)
          prev <- comments_by_col[[key]]
          txt <- stringr::str_squish(v)
          comments_by_col[[key]] <- if (is.null(prev)) txt else paste(prev, txt, sep = "; ")
        }
      }
      next
    }

    analyte_raw_val <- normalise_lab_text(label)
    analyte_norm <- toupper(stringr::str_squish(analyte_raw_val))
    is_allowed <- analyte_norm %in% allowed_norm
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
        # Kept WITH its value (A75) - the comparison against the real ALS
        # result happens in assemble/reconcile, which can see the ALS data.
        if (nonempty(value_raw_cell)) {
          als_candidates[[length(als_candidates) + 1]] <- tibble::tibble(
            source_ref = source_ref,
            feature_raw = feature_by_col[[as.character(j)]],
            analyte_raw = analyte_raw_val,
            units_raw = .st_acirl_repair_units(analyte_raw_val, units_cell),
            value_raw = value_raw_cell
          )
        }
        skipped_rows[[length(skipped_rows) + 1]] <- tibble::tibble(
          source_ref = source_ref, reason = "lab_data_dropped"
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
    als_work_orders = als_work_orders
  )
}

# Observation/comments row labels. Bare "Comments" is the fixture form; the
# real corpus uses longer variants, all of which attach to the sample rather
# than producing a result row.
.st_acirl_is_comment_label <- function(label) {
  grepl("^comments$", label, ignore.case = TRUE) ||
    grepl("comment|observation", label, ignore.case = TRUE)
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
