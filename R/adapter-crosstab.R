# Plan 05 - ALS crosstab adapters: shared `parse_crosstab()` core plus the
# `als_xtab` and `als_enmrg` dialect adapters. Both formats share the same
# structural shape (metadata rows, an analyte header row, then method-group
# rows and analyte rows with one column per sample) but differ in label
# text/column position, first-row marker, and text encoding (PLAN-05's
# dialect table). Per CONTRACT A29, every label is located by regex against
# cell *content* on each row - never a fixed column index - because real
# files are observed to vary in exact column position.

# Dialect definitions (PLAN-05 table). `first_row_regex` is the section
# start marker (also the match() discriminator between the two adapters);
# `label_regex` locates the "ALS Sample Number(:)" row, whose column
# position differs between XTAB and ENMRG; `encoding` is the CSV read
# locale (XTAB ships as legacy latin-1/MacRoman bytes, ENMRG as UTF-8).
.st_crosstab_dialects <- list(
  als_xtab = list(
    id = "als_xtab",
    first_row_regex = "^Matrix:",
    label_regex = "^ALS Sample num",
    encoding = "latin1"
  ),
  als_enmrg = list(
    id = "als_enmrg",
    first_row_regex = "^Client - Matrix:",
    label_regex = "^ALS Sample num",
    encoding = "UTF-8"
  )
)

#' Construct the `als_xtab` adapter
#'
#' ALS "XTAB" crosstab export adapter (PLAN-05). Registered under id
#' `"als_xtab"` by [register_builtin_adapters()] in `R/zzz.R`.
#'
#' @return a list with elements `id`, `version`, `match`, `parse`.
#' @keywords internal
#' @noRd
als_xtab_adapter <- function() {
  version <- "1.0"
  dialect <- .st_crosstab_dialects$als_xtab
  list(
    id = dialect$id,
    version = version,
    match = function(file_meta) .st_crosstab_match(file_meta, dialect),
    parse = function(path, file_meta) .st_crosstab_parse(path, file_meta, dialect, version)
  )
}

#' Construct the `als_enmrg` adapter
#'
#' ALS "ENMRG" crosstab export adapter (PLAN-05) - same family as
#' `als_xtab` but UTF-8 encoded, with QC sample columns present. Registered
#' under id `"als_enmrg"` by [register_builtin_adapters()] in `R/zzz.R`.
#'
#' @return a list with elements `id`, `version`, `match`, `parse`.
#' @keywords internal
#' @noRd
als_enmrg_adapter <- function() {
  version <- "1.0"
  dialect <- .st_crosstab_dialects$als_enmrg
  list(
    id = dialect$id,
    version = version,
    match = function(file_meta) .st_crosstab_match(file_meta, dialect),
    parse = function(path, file_meta) .st_crosstab_parse(path, file_meta, dialect, version)
  )
}

# --- R-5.2 match() ------------------------------------------------------

# `format` tier (never `exact` - R-5.2: ESdat must outrank crosstabs at
# source-preference time) when the dialect's `first_row_regex` matches the
# very first row/line AND the file contains a `Workgroup:` cell somewhere in
# its lead rows; `no` otherwise. XTAB and ENMRG must never both claim the
# same file: XTAB requires `^Matrix:`, ENMRG requires `^Client - Matrix:`,
# which are mutually exclusive as first-row markers.
.st_crosstab_match <- function(fm, dialect) {
  if (!fm$ext %in% c("csv", "xls", "xlsx")) {
    return("no")
  }

  lines <- .st_crosstab_peek_lines(fm)
  if (is.null(lines) || length(lines) == 0) {
    return("no")
  }

  first_ok <- isTRUE(grepl(dialect$first_row_regex, lines[[1]]))
  workgroup_ok <- any(grepl("Workgroup:", lines, fixed = TRUE))

  if (first_ok && workgroup_ok) "format" else "no"
}

# The first few "rows" of a candidate file as character strings (one string
# per row, cells comma-joined), used only to test for structural markers -
# never for content parsing. CSV: split file_meta()'s latin-1 peek on line
# breaks (adequate because the markers tested are pure ASCII, so a wrong
# encoding guess at this stage cannot hide them). XLS/XLSX: read a handful
# of rows as text via readxl, since the file is binary and file_meta()'s
# byte peek cannot be interpreted as text at all.
.st_crosstab_peek_lines <- function(fm) {
  if (identical(fm$ext, "csv")) {
    txt <- fm$peek
    if (is.null(txt) || !nzchar(txt)) {
      return(NULL)
    }
    return(strsplit(txt, "\r\n|\n")[[1]])
  }

  df <- tryCatch(
    suppressMessages(readxl::read_excel(
      fm$path, sheet = 1, col_names = FALSE, col_types = "text", n_max = 10
    )),
    error = function(e) NULL
  )
  if (is.null(df) || nrow(df) == 0) {
    return(NULL)
  }
  mat <- as.matrix(df)
  apply(mat, 1, function(r) paste(ifelse(is.na(r), "", r), collapse = ","))
}

# --- parse() dispatch + crash containment --------------------------------

.st_crosstab_parse <- function(path, fm, dialect, version) {
  tryCatch(
    .st_crosstab_parse_impl(path, fm, dialect, version),
    error = function(e) {
      if (inherits(e, "sampletidy_parse_error")) {
        stop(e)
      }
      cli::cli_abort(
        "Failed to parse {.path {path}} as an ALS crosstab ({dialect$id}) file: {conditionMessage(e)}",
        class = "sampletidy_parse_error",
        parent = e
      )
    }
  )
}

.st_crosstab_parse_impl <- function(path, fm, dialect, version) {
  mat <- .st_crosstab_read_grid(path, fm, dialect)
  .st_crosstab_walk_grid(mat, fm, dialect, version)
}

# Read the whole file as an untyped character grid (matrix): csv via
# readr with the dialect's declared locale encoding, xls/xlsx via readxl
# with every column forced to text. No column names, no type guessing.
.st_crosstab_read_grid <- function(path, fm, dialect) {
  if (identical(fm$ext, "csv")) {
    df <- readr::read_csv(
      path,
      col_types = readr::cols(.default = readr::col_character()),
      col_names = FALSE,
      locale = readr::locale(encoding = dialect$encoding),
      show_col_types = FALSE
    )
  } else if (fm$ext %in% c("xls", "xlsx")) {
    df <- suppressMessages(readxl::read_excel(
      path, sheet = 1, col_names = FALSE, col_types = "text"
    ))
  } else {
    cli::cli_abort(
      "{.path {path}} has an unsupported extension for the crosstab adapter ({fm$ext}).",
      class = "sampletidy_parse_error"
    )
  }
  as.matrix(df)
}

# --- R-5.1 shared parser: the row-by-row state machine -------------------

# Look up `key` in a list built with `[[as.character(col)]] <- value`
# assignments, returning NA_character_ (not NULL) when the column was never
# populated for the current section (e.g. a sample column with no Sample
# Date recorded).
.st_ct_lookup <- function(lst, key) {
  v <- lst[[key]]
  if (is.null(v)) NA_character_ else v
}

# Map a raw Sample-Type cell to the IR's controlled vocabulary
# (.st_ir_sample_type_allowed in R/ir.R): `REG` -> `"Normal"`, everything
# else (QC codes like `LCS`/`MB`) verbatim, missing -> `"unknown"`.
.st_crosstab_sample_type <- function(raw) {
  if (is.na(raw) || !nzchar(raw)) {
    return("unknown")
  }
  if (identical(raw, "REG")) {
    return("Normal")
  }
  raw
}

# First column index in `row` whose (already-trimmed) value matches
# `pattern`, or NA_integer_ if none does. `row` is a character vector that
# may contain NA (blank cells).
.st_crosstab_find_col <- function(row, pattern, ignore_case = TRUE) {
  hits <- which(!is.na(row) & nzchar(row) & grepl(pattern, row, ignore.case = ignore_case))
  if (length(hits) == 0) NA_integer_ else hits[[1]]
}

# Safe scalar extraction: NA_character_ if `i` is NA or out of range.
.st_ct_at <- function(row, i) {
  if (is.na(i) || i < 1 || i > length(row)) {
    return(NA_character_)
  }
  row[[i]]
}

#' Shared crosstab parser core
#'
#' Walks the untyped character grid one row at a time, tracking the current
#' section's metadata (matrix, workgroup/work order, per-column sample
#' type/date/feature/lab-sample-id, and the running method-group text) and
#' emitting one `samples` row per sample column (as soon as the "ALS Sample
#' Number" row is seen) and one `results` row per non-skipped analyte x
#' sample-column cell. A file may contain multiple stacked `Matrix:`
#' sections; encountering the dialect's `first_row_regex` resets all
#' section-scoped state.
#'
#' @param mat an untyped character matrix (one row per file row, `NA` for
#'   blank cells), as produced by [.st_crosstab_read_grid()].
#' @param fm a [file_meta()] list for the source file.
#' @param dialect one of `.st_crosstab_dialects`' elements.
#' @param version the adapter's version string (for the `adapter` IR column).
#' @return a list with elements `results`, `samples`, `report`
#'   (`n_rows`, `n_by_sample_type`, `skipped`, `header`, `warnings`).
#' @keywords internal
#' @noRd
.st_crosstab_walk_grid <- function(mat, fm, dialect, version) {
  n_rows <- nrow(mat)
  n_cols <- ncol(mat)
  adapter_tag <- paste0(dialect$id, "/", version)

  warnings_vec <- character(0)

  revision <- fm$revision_guess
  if (is.na(revision)) {
    warnings_vec <- c(warnings_vec, sprintf(
      "%s: no revision found in filename; defaulting to revision 0.", fm$filename
    ))
    revision <- 0L
  } else {
    revision <- as.integer(revision)
  }

  # Section-scoped state (reset whenever a new Matrix:/Client - Matrix: row
  # is encountered).
  section_matrix <- NA_character_
  section_workgroup <- NA_character_
  sample_type_by_col <- list()
  sample_date_by_col <- list()
  feature_by_col <- list()
  lab_sample_id_by_col <- list()
  method_raw <- NA_character_
  cas_col <- NA_integer_
  unit_col <- NA_integer_
  rl_col <- NA_integer_
  analyte_col <- NA_integer_
  header_seen <- FALSE
  sample_cols <- integer(0)

  results_rows <- list()
  samples_rows <- list()
  skipped_rows <- list()

  for (r in seq_len(n_rows)) {
    row_raw <- mat[r, ]
    row_trimmed <- ifelse(is.na(row_raw), NA_character_, trimws(row_raw))
    col1 <- .st_ct_at(row_trimmed, 1L)

    # New section marker: "Matrix:" (XTAB) / "Client - Matrix:" (ENMRG).
    if (!is.na(col1) && grepl(dialect$first_row_regex, col1)) {
      section_matrix <- .st_ct_at(row_trimmed, 2L)
      section_workgroup <- NA_character_
      sample_type_by_col <- list()
      sample_date_by_col <- list()
      feature_by_col <- list()
      lab_sample_id_by_col <- list()
      method_raw <- NA_character_
      cas_col <- NA_integer_
      unit_col <- NA_integer_
      rl_col <- NA_integer_
      analyte_col <- NA_integer_
      header_seen <- FALSE
      sample_cols <- integer(0)
      next
    }

    if (!is.na(col1) && grepl("^Workgroup:$", col1, ignore.case = TRUE)) {
      section_workgroup <- .st_ct_at(row_trimmed, 2L)
      if (!is.na(fm$work_order_guess) && !is.na(section_workgroup) &&
        !identical(section_workgroup, fm$work_order_guess)) {
        warnings_vec <- c(warnings_vec, sprintf(
          "Workgroup '%s' does not match the filename's work-order guess '%s' (%s); using the Workgroup value.",
          section_workgroup, fm$work_order_guess, fm$filename
        ))
      }
      next
    }

    if (!is.na(col1) && grepl("^Sample Type:$", col1, ignore.case = TRUE)) {
      for (c in seq_len(n_cols)) {
        v <- .st_ct_at(row_trimmed, c)
        if (!is.na(v) && nzchar(v)) sample_type_by_col[[as.character(c)]] <- v
      }
      next
    }

    if (!is.na(col1) && grepl("^Sample Date:$", col1, ignore.case = TRUE)) {
      for (c in seq_len(n_cols)) {
        v <- .st_ct_at(row_trimmed, c)
        if (!is.na(v) && nzchar(v)) sample_date_by_col[[as.character(c)]] <- v
      }
      next
    }

    if (!is.na(col1) && grepl("^Client sample ID", col1, ignore.case = TRUE)) {
      for (c in seq_len(n_cols)) {
        v <- .st_ct_at(row_trimmed, c)
        if (!is.na(v) && nzchar(v)) feature_by_col[[as.character(c)]] <- v
      }
      next
    }

    if (!is.na(col1) && (grepl("^Project name", col1, ignore.case = TRUE) ||
      grepl("^Depth", col1, ignore.case = TRUE))) {
      next
    }

    # The "ALS Sample Number(:)"/"ALS Sample number:" row: locates the
    # sample columns for this section and, since every other per-column
    # vector (type/date/feature) has already been captured by this point in
    # every observed file layout, emits the section's `samples` rows now.
    label_col <- .st_crosstab_find_col(row_trimmed, dialect$label_regex)
    if (!is.na(label_col)) {
      for (c in seq_len(n_cols)) {
        if (c == label_col) next
        v <- .st_ct_at(row_trimmed, c)
        if (!is.na(v) && nzchar(v)) {
          lab_sample_id_by_col[[as.character(c)]] <- v
          sample_cols <- union(sample_cols, c)
        }
      }
      for (c in sample_cols) {
        key <- as.character(c)
        samples_rows[[length(samples_rows) + 1]] <- tibble::tibble(
          source_hash = fm$hash,
          source_ref = sprintf("r%dc%d", r, c),
          work_order = section_workgroup,
          org = "ALS",
          adapter = adapter_tag,
          lab_sample_id = .st_ct_lookup(lab_sample_id_by_col, key),
          feature_raw = .st_ct_lookup(feature_by_col, key),
          sample_datetime_raw = .st_ct_lookup(sample_date_by_col, key),
          sample_type = .st_crosstab_sample_type(.st_ct_lookup(sample_type_by_col, key)),
          parent_sample = NA_character_,
          matrix_raw = section_matrix,
          sampler = NA_character_,
          comments = NA_character_,
          confidence = 1
        )
      }
      next
    }

    # The analyte header row: "Analyte, CAS Number, Unit, Limit of
    # reporting" (XTAB) or "Analyte grouping, Analyte, CAS Number, Unit,
    # Limit of reporting" (ENMRG). Located via its "CAS Number" cell; the
    # other column positions are then found by regex within the same row -
    # never assumed from a fixed offset (CONTRACT A29).
    header_cas_col <- .st_crosstab_find_col(row_trimmed, "^CAS Number$")
    if (!is.na(header_cas_col)) {
      cas_col <- header_cas_col
      unit_col <- .st_crosstab_find_col(row_trimmed, "^Unit$")
      rl_col <- .st_crosstab_find_col(row_trimmed, "^Limit of reporting$")
      analyte_col <- .st_crosstab_find_col(row_trimmed, "^Analyte$")
      header_seen <- TRUE
      next
    }

    if (!header_seen) {
      next
    }
    if (is.na(col1) || !nzchar(col1)) {
      next
    }

    has_sample_values <- length(sample_cols) > 0 &&
      any(!is.na(row_trimmed[sample_cols]) & nzchar(row_trimmed[sample_cols]))

    if (!has_sample_values) {
      # Method-group row (e.g. "EA005P: pH by PC Titrator"): zero result
      # rows, but sets method_raw for the analyte rows that follow, until
      # the next method-group row.
      method_raw <- normalise_lab_text(col1)
      next
    }

    # Analyte row.
    analyte_raw <- normalise_lab_text(.st_ct_at(row_trimmed, analyte_col))
    cas_val <- .st_ct_at(row_trimmed, cas_col)
    cas_number <- if (is.na(cas_val) || !nzchar(cas_val)) NA_character_ else cas_val
    unit_val <- .st_ct_at(row_trimmed, unit_col)
    units_raw <- if (is.na(unit_val)) NA_character_ else normalise_lab_text(unit_val)
    rl_val <- suppressWarnings(as.numeric(.st_ct_at(row_trimmed, rl_col)))

    for (c in sample_cols) {
      value_raw_cell <- .st_ct_at(row_trimmed, c)
      pv <- parse_value(value_raw_cell)
      source_ref <- sprintf("r%dc%d", r, c)

      if (!is.na(pv$skip_reason)) {
        skipped_rows[[length(skipped_rows) + 1]] <- tibble::tibble(
          source_ref = source_ref, reason = pv$skip_reason
        )
        next
      }

      key <- as.character(c)
      results_rows[[length(results_rows) + 1]] <- tibble::tibble(
        source_hash = fm$hash,
        source_ref = source_ref,
        work_order = section_workgroup,
        revision = revision,
        org = "ALS",
        adapter = adapter_tag,
        lab_sample_id = .st_ct_lookup(lab_sample_id_by_col, key),
        sample_type = .st_crosstab_sample_type(.st_ct_lookup(sample_type_by_col, key)),
        feature_raw = .st_ct_lookup(feature_by_col, key),
        analyte_raw = analyte_raw,
        cas_number = cas_number,
        method_raw = method_raw,
        total_or_filtered = NA_character_,
        units_raw = units_raw,
        value_raw = value_raw_cell,
        value_num = pv$value_num,
        value_chr = pv$value_chr,
        below_detection = grepl("^<", value_raw_cell),
        rl = rl_val,
        lab_qualifier = NA_character_,
        analysed_date = as.Date(NA_character_),
        comments = NA_character_,
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
  skipped <- if (length(skipped_rows) == 0) {
    tibble::tibble(source_ref = character(0), reason = character(0))
  } else {
    dplyr::bind_rows(skipped_rows)
  }

  list(
    results = results,
    samples = samples,
    report = list(
      n_rows = n_rows,
      n_by_sample_type = table(results$sample_type),
      skipped = skipped,
      header = NULL,
      warnings = warnings_vec
    )
  )
}
