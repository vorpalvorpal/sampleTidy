# Plan 05 - ALS crosstab adapters: shared `parse_crosstab()` core plus the
# `als_xtab` and `als_enmrg` dialect adapters. Both formats share the same
# structural shape (metadata rows, an analyte header row, then method-group
# rows and analyte rows with one column per sample) but differ in label
# text/column position, first-row marker, and text encoding (PLAN-05's
# dialect table).
#
# CONTRACT A34 (real-corpus correction, 2026-07-15): the true layout, verified
# against real XTAB/ENMRG exports, differs from what an earlier WIP parser
# (silently) assumed:
#  - `Analyte grouping/Analyte` is ONE column (col 0) in BOTH dialects,
#    holding both method-group rows (e.g. "EA005P: pH by PC Titrator" with no
#    sample-column values) and analyte rows (with values) - never a
#    two-column split, and never a bare `^Analyte$` header.
#  - Per-sample metadata labels (`Sample Type:`, `ALS Sample Number:`/
#    `ALS Sample number:`, `Sample [Dd]ate:`, `Client sample ID (...)`,
#    `Site:`/`Sample Site:`, `Purchase Order:`) sit at column 3 (XTAB) / 4
#    (ENMRG), 0-based, with their per-sample values several columns further
#    right (col 5+) - NOT adjacent, and NOT at column 0. Every physical row
#    can carry BOTH a section-scalar label (col 0/1) AND a per-sample label
#    (col 3/4..) at once (e.g. the `Matrix:` row also carries `Sample Type:`;
#    the `Workgroup:` row also carries `ALS Sample Number:`). Every label is
#    therefore located by regex against the WHOLE row, every row is checked
#    against every known label pattern (not just the first match), and only
#    the leftover, doubly-unrecognised rows fall through to method-group/
#    analyte-row handling.
#  - Header spellings differ: XTAB writes `Unit` / `Limit of reporting`;
#    ENMRG writes `Units` / `LOR`. Both are matched by one shared pattern.

# Dialect definitions (PLAN-05 table). `first_row_regex` is the section
# start marker (also the match() discriminator between the two adapters and
# the trigger for a full per-section state reset inside the parser);
# `label_regex` locates the "ALS Sample Number(:)"/"ALS Sample number:" row,
# whose column position differs between XTAB and ENMRG; `encoding` is the CSV
# read locale (XTAB ships as legacy latin-1 bytes, ENMRG as UTF-8).
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
# which are mutually exclusive as first-row markers. A34/A37: real XTAB
# `.XLS` is SpreadsheetML XML, which `readxl` cannot read - the peek below
# returns NULL for it, so `match()` gracefully returns `"no"` (no crash);
# the `.csv` twin carries the data. SpreadsheetML parsing is parked
# post-MVP.
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
# `suppressWarnings()`: real ENMRG exports carry a trailing "QC - Matrix:"
# reconciliation block (a section marker this parser deliberately does not
# recognise/parse - see `.st_crosstab_walk_grid`'s "unsupported section"
# handling) whose rows are far wider than the primary section, which makes
# readr emit benign "N columns expected / M columns actual" parsing-problem
# warnings for those (skipped) rows; the primary section itself always
# parses cleanly.
.st_crosstab_read_grid <- function(path, fm, dialect) {
  if (identical(fm$ext, "csv")) {
    df <- suppressWarnings(readr::read_csv(
      path,
      col_types = readr::cols(.default = readr::col_character()),
      col_names = FALSE,
      locale = readr::locale(encoding = dialect$encoding),
      show_col_types = FALSE
    ))
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
# may contain NA (blank cells). Searches every column - CONTRACT A34/A29:
# real per-sample labels sit at column 3/4, not column 0, so callers must
# never assume a fixed position.
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

# Capture every non-empty cell strictly to the right of `label_col` into
# `dict`, keyed by absolute (1-based) column index as a string. This is the
# per-sample capture rule (CONTRACT A34): per-sample values sit at the
# sample columns to the right of their row's label cell - sometimes
# immediately adjacent (ENMRG), sometimes with an empty gap column in
# between (XTAB) - either way, "non-empty cells right of the label" is the
# correct, position-independent rule. Must NOT be used for section-scalar
# labels (`Matrix:`, `Workgroup:`), whose value is the single next cell -
# using this rule for those would vacuum up the next label's text too.
.st_ct_capture_right <- function(row, label_col, dict) {
  n_cols <- length(row)
  if (is.na(label_col) || label_col >= n_cols) {
    return(dict)
  }
  for (c in (label_col + 1):n_cols) {
    v <- row[[c]]
    if (!is.na(v) && nzchar(v)) {
      dict[[as.character(c)]] <- v
    }
  }
  dict
}

# Any cell whose (trimmed) text ends in "Matrix:" - i.e. a section marker of
# *some* kind, recognised or not. Real ENMRG exports carry a trailing
# "QC - Matrix:" reconciliation block after the primary "Client - Matrix:"
# section: it is NOT one of this file's recognised dialects (its own
# `ALS Sample number:` row reuses primary-section sample IDs for other work
# orders' QC batches, its column count balloons far past the primary
# section, and PLAN-05/CONTRACT A34 both describe "recent files carry a
# single Matrix: section" as the norm), so this parser deliberately does
# NOT parse it - it must not crash on it or, worse, silently corrupt the
# primary section's already-captured per-column state by re-using the same
# column indices for different samples. `.st_crosstab_walk_grid()` uses this
# to detect *any* Matrix:-style marker, decide whether it is the dialect's
# own (-> reset and parse the new section) or a foreign one (-> skip every
# row until a recognised marker reappears, if ever).
.ST_CROSSTAB_ANY_MARKER_RE <- "Matrix:$"

#' Shared crosstab parser core
#'
#' Walks the untyped character grid one row at a time, tracking the current
#' section's metadata (matrix, workgroup/work order, per-column sample
#' type/date/feature/lab-sample-id, and the running method-group text).
#' Every row is checked against every known label pattern (a single row may
#' carry a section-scalar label AND a per-sample label at once - CONTRACT
#' A34); once a section's analyte header row is located, all per-sample
#' state for that section is final and one `samples` row per sample column
#' is emitted (deferred to the header row, not the "ALS Sample Number" row,
#' because per-sample labels are observed to arrive both before AND after it
#' in real files). Subsequent rows are either method-group rows (analyte
#' column text, no sample-column values - sets `method_raw` for following
#' rows) or analyte rows (emit one `results` row per non-skipped analyte x
#' sample-column cell). A file may contain multiple stacked sections whose
#' marker matches the dialect's `first_row_regex`; a marker that looks like
#' a section start but does NOT match the dialect (e.g. a trailing
#' "QC - Matrix:" reconciliation block in real ENMRG exports) is skipped in
#' full, rather than parsed or allowed to corrupt state.
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

  # Section-scoped state (reset whenever a new, dialect-recognised
  # Matrix:/Client - Matrix: row is encountered).
  section_matrix <- NA_character_
  section_workgroup <- NA_character_
  sample_type_by_col <- list()
  sample_date_by_col <- list()
  feature_by_col <- list()
  lab_sample_id_by_col <- list()
  sample_number_row <- NA_integer_
  method_raw <- NA_character_
  cas_col <- NA_integer_
  unit_col <- NA_integer_
  rl_col <- NA_integer_
  analyte_col <- NA_integer_
  header_seen <- FALSE
  sample_cols <- integer(0)
  in_unsupported_section <- FALSE

  reset_section_state <- function() {
    sample_type_by_col <<- list()
    sample_date_by_col <<- list()
    feature_by_col <<- list()
    lab_sample_id_by_col <<- list()
    sample_number_row <<- NA_integer_
    method_raw <<- NA_character_
    cas_col <<- NA_integer_
    unit_col <<- NA_integer_
    rl_col <<- NA_integer_
    analyte_col <<- NA_integer_
    header_seen <<- FALSE
    sample_cols <<- integer(0)
  }

  results_rows <- list()
  samples_rows <- list()
  skipped_rows <- list()

  for (r in seq_len(n_rows)) {
    row_raw <- mat[r, ]
    row_trimmed <- ifelse(is.na(row_raw), NA_character_, trimws(row_raw))
    handled <- FALSE

    # -- Section marker: any "...Matrix:" cell, recognised or not ---------
    marker_col <- .st_crosstab_find_col(row_trimmed, .ST_CROSSTAB_ANY_MARKER_RE)
    if (!is.na(marker_col)) {
      if (grepl(dialect$first_row_regex, row_trimmed[[marker_col]])) {
        section_matrix <- .st_ct_at(row_trimmed, marker_col + 1L)
        section_workgroup <- NA_character_
        reset_section_state()
        in_unsupported_section <- FALSE
        handled <- TRUE
        # Do NOT `next` here (A34): this same physical row also carries
        # this section's "Sample Type:" label, which must still be read
        # below.
      } else {
        # A foreign section marker (e.g. real ENMRG's trailing
        # "QC - Matrix:" block): skip it and everything after it until a
        # recognised marker reappears (if ever).
        in_unsupported_section <- TRUE
        next
      }
    }

    if (in_unsupported_section) {
      next
    }

    # -- Workgroup: (section-scalar; value = the single next cell) --------
    wg_col <- .st_crosstab_find_col(row_trimmed, "^Workgroup:$")
    if (!is.na(wg_col)) {
      section_workgroup <- .st_ct_at(row_trimmed, wg_col + 1L)
      if (!is.na(fm$work_order_guess) && !is.na(section_workgroup) &&
        !identical(section_workgroup, fm$work_order_guess)) {
        warnings_vec <- c(warnings_vec, sprintf(
          "Workgroup '%s' does not match the filename's work-order guess '%s' (%s); using the Workgroup value.",
          section_workgroup, fm$work_order_guess, fm$filename
        ))
      }
      handled <- TRUE
    }

    # -- Sample Type: (per-sample) -----------------------------------------
    st_col <- .st_crosstab_find_col(row_trimmed, "^Sample Type:$")
    if (!is.na(st_col)) {
      sample_type_by_col <- .st_ct_capture_right(row_trimmed, st_col, sample_type_by_col)
      handled <- TRUE
    }

    # -- ALS Sample Number:/ALS Sample number: (per-sample; defines the
    # section's sample columns) --------------------------------------------
    sn_col <- .st_crosstab_find_col(row_trimmed, dialect$label_regex)
    if (!is.na(sn_col)) {
      lab_sample_id_by_col <- .st_ct_capture_right(row_trimmed, sn_col, lab_sample_id_by_col)
      sample_number_row <- r
      handled <- TRUE
    }

    # -- Sample Date:/Sample date: ------------------------------------------
    sd_col <- .st_crosstab_find_col(row_trimmed, "^Sample Date:$")
    if (!is.na(sd_col)) {
      sample_date_by_col <- .st_ct_capture_right(row_trimmed, sd_col, sample_date_by_col)
      handled <- TRUE
    }

    # -- Client sample ID (1st)/(Primary): -> feature_raw --------------------
    ci_col <- .st_crosstab_find_col(row_trimmed, "Client sample ID.*\\((1st|Primary)\\)")
    if (!is.na(ci_col)) {
      feature_by_col <- .st_ct_capture_right(row_trimmed, ci_col, feature_by_col)
      handled <- TRUE
    }

    # -- Other recognised-but-IR-irrelevant labels: consumed so they never
    # fall through and get misread as method-group/analyte rows. ----------
    for (skip_pat in c(
      "Client sample ID.*\\((2nd|Secondary)\\)", "(Sample )?Site:$",
      "^Purchase Order:$", "^Depth", "^Project name"
    )) {
      if (!is.na(.st_crosstab_find_col(row_trimmed, skip_pat))) {
        handled <- TRUE
      }
    }

    # -- Analyte header row: "Analyte grouping/Analyte, CAS Number,
    # Unit(s), Limit of reporting/LOR" - located via its "CAS Number" cell;
    # every other column is then found by its own regex on the SAME row,
    # never assumed from a fixed offset (CONTRACT A29/A34). Finalises this
    # section's sample columns and emits its `samples` rows: every
    # per-sample label row (Sample Type/ALS Sample Number/Sample Date/
    # Client sample ID) is always seen before the header in every observed
    # real file, so all per-column state is complete by this point.
    header_cas_col <- .st_crosstab_find_col(row_trimmed, "^CAS Number$")
    if (!is.na(header_cas_col)) {
      cas_col <- header_cas_col
      unit_col <- .st_crosstab_find_col(row_trimmed, "^Units?$")
      rl_col <- .st_crosstab_find_col(row_trimmed, "^(Limit of reporting|LOR)$")
      analyte_col <- .st_crosstab_find_col(row_trimmed, "Analyte grouping")
      header_seen <- TRUE
      sample_cols <- sort(as.integer(names(lab_sample_id_by_col)))

      for (c in sample_cols) {
        key <- as.character(c)
        samples_rows[[length(samples_rows) + 1]] <- tibble::tibble(
          source_hash = fm$hash,
          source_ref = sprintf("r%dc%d", sample_number_row, c),
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
      handled <- TRUE
    }

    if (handled) {
      next
    }

    if (!header_seen || is.na(analyte_col)) {
      next
    }
    cell_at_analyte <- .st_ct_at(row_trimmed, analyte_col)
    if (is.na(cell_at_analyte) || !nzchar(cell_at_analyte)) {
      next
    }

    has_sample_values <- length(sample_cols) > 0 &&
      any(!is.na(row_trimmed[sample_cols]) & nzchar(row_trimmed[sample_cols]))

    if (!has_sample_values) {
      # Method-group row (e.g. "EA005P: pH by PC Titrator"): zero result
      # rows, but sets method_raw for the analyte rows that follow, until
      # the next method-group row.
      method_raw <- normalise_lab_text(cell_at_analyte)
      next
    }

    # Analyte row.
    analyte_raw <- normalise_lab_text(cell_at_analyte)
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
