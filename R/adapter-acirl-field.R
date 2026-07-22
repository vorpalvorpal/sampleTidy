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
  "no"
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

  for (idx in water_idx) {
    sheet_name <- sheet_names[[idx]]
    ws <- .st_acirl_parse_water_sheet(path, sheet_name, field_analytes)
    warnings_vec <- c(warnings_vec, ws$warnings)
    if (length(ws$skipped) > 0) {
      skipped_list <- c(skipped_list, ws$skipped)
    }

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

  list(
    results = results,
    samples = samples,
    report = list(
      n_rows = nrow(results) + nrow(samples),
      n_by_sample_type = table(results$sample_type),
      skipped = skipped,
      header = header,
      warnings = warnings_vec
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

# --- R-6.3 water sheets ----------------------------------------------------

# Parses one water sheet into raw (pre-IR) results/samples row lists plus
# skipped rows and warnings. Layout (tests/testthat/fixtures/acirl/README.md):
# a "Site Name" row carries the `Units` marker (locates the header row and,
# one column to its right, the units column) plus one feature name per
# sample column; the next row matching `(?i)date` carries Excel-serial dates
# (filled down across columns); each subsequent labelled row is either
# "Comments" (attaches to samples, not results) or a candidate analyte row
# (kept only if on the configured field-analyte allowlist; everything else,
# including the ALS lab-result copies below the block terminator, is
# recorded as `lab_data_dropped`).
.st_acirl_parse_water_sheet <- function(path, sheet_name, field_analytes) {
  empty_out <- function(skipped = list(), warnings = character(0)) {
    list(results = list(), samples = list(), skipped = skipped, warnings = warnings)
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

  # Units marker locates the header row and the units column.
  units_hits <- str_which_df(grid, "^Units$", multiple_matches = TRUE)
  if (nrow(units_hits) == 0) {
    warn <- sprintf("Sheet '%s': no 'Units' marker found; sheet skipped.", sheet_name)
    return(empty_out(
      skipped = list(tibble::tibble(source_ref = sheet_name, reason = "no_units_marker")),
      warnings = warn
    ))
  }
  header_row <- units_hits$row[[1]]
  header_col <- units_hits$col[[1]]

  # Block terminator: the last row (column A) matching the field/comments
  # pattern, at or after the header row.
  col1 <- trimws(mat[, 1])
  term_hits <- which(grepl(.st_acirl_terminator_re, col1, ignore.case = TRUE))
  term_hits <- term_hits[term_hits >= header_row]
  if (length(term_hits) == 0) {
    warn <- sprintf(
      "Sheet '%s': could not locate the end of the field-data block; sheet skipped.",
      sheet_name
    )
    return(empty_out(
      skipped = list(tibble::tibble(source_ref = sheet_name, reason = "no_field_block")),
      warnings = warn
    ))
  }
  terminator_row <- max(term_hits)

  n_block_rows <- terminator_row - header_row + 1
  warnings_local <- character(0)
  if (n_block_rows > 20) {
    warnings_local <- c(warnings_local, sprintf(
      "Sheet '%s' field-data block has %d rows (more than 20); check for a layout mistake.",
      sheet_name, n_block_rows
    ))
  }

  # Sample columns + feature names, from the header row.
  sample_cols <- integer(0)
  feature_by_col <- list()
  if (n_col > header_col) {
    for (j in (header_col + 1):n_col) {
      v <- mat[header_row, j]
      if (!is.na(v) && nzchar(trimws(v))) {
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

  # Date row: first row after the header matching `(?i)date`.
  date_row <- NA_integer_
  if (header_row < n_row) {
    for (r in (header_row + 1):n_row) {
      lbl <- trimws(mat[r, 1])
      if (!is.na(lbl) && grepl("date", lbl, ignore.case = TRUE)) {
        date_row <- r
        break
      }
    }
  }
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
    v <- mat[date_row, j]
    if (!is.na(v) && nzchar(trimws(v))) {
      last_val <- trimws(v)
    }
    date_serial_by_col[[as.character(j)]] <- last_val
  }
  sample_datetime_by_col <- lapply(date_serial_by_col, function(raw) {
    if (is.na(raw)) {
      return(NA_character_)
    }
    num <- suppressWarnings(as.numeric(raw))
    if (is.na(num)) NA_character_ else format(excel_date(num), "%d/%m/%Y")
  })

  # Parameter rows: everything from just after the date row to the end of
  # the sheet (not just the terminator row - ALS lab-result copies below
  # the terminator must still be scanned so they can be recorded as
  # lab_data_dropped rather than silently ignored).
  results_rows <- list()
  skipped_rows <- list()
  comments_by_col <- list()

  if (date_row < n_row) {
    for (r in (date_row + 1):n_row) {
      label_raw <- mat[r, 1]
      if (is.na(label_raw) || !nzchar(trimws(label_raw))) {
        next
      }
      label <- trimws(label_raw)

      if (grepl("^comments$", label, ignore.case = TRUE)) {
        for (j in sample_cols) {
          v <- mat[r, j]
          if (!is.na(v) && nzchar(trimws(v))) {
            comments_by_col[[as.character(j)]] <- stringr::str_squish(v)
          }
        }
        next
      }

      analyte_raw_val <- normalise_lab_text(label)
      analyte_norm <- toupper(stringr::str_squish(analyte_raw_val))
      allowed_norm <- toupper(stringr::str_squish(field_analytes))
      is_allowed <- analyte_norm %in% allowed_norm
      units_cell <- mat[r, header_col]

      for (j in sample_cols) {
        value_raw_cell <- mat[r, j]
        source_ref <- sprintf("%s!r%dc%d", sheet_name, r, j)

        if (!is_allowed) {
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
          value_raw = trimws(value_raw_cell),
          value_num = pv$value_num,
          value_chr = pv$value_chr,
          below_detection = grepl("^<", trimws(value_raw_cell))
        )
      }
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
    warnings = warnings_local
  )
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
