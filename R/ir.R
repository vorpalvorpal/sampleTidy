# Plan 03 - R-3.1 IR contract: ir_results()/ir_samples() build validated
# tibbles with exactly the columns of DESIGN §4.1/§4.2 (names, types, order
# pinned there); ir_validate(x, kind) aborts on structural/content
# violations.

# Canonical column order + types (DESIGN §4.1 `results`, §4.2 `samples`).
# Kept as named character vectors so both order (names(...)) and per-column
# type (values) are pinned in one place.
.st_ir_results_types <- c(
  source_hash = "character", source_ref = "character", work_order = "character",
  revision = "integer", org = "character", adapter = "character",
  lab_sample_id = "character", sample_type = "character", feature_raw = "character",
  analyte_raw = "character", cas_number = "character", method_raw = "character",
  total_or_filtered = "character", units_raw = "character", value_raw = "character",
  value_num = "double", value_chr = "character", below_detection = "logical",
  rl = "double", lab_qualifier = "character", analysed_date = "Date",
  comments = "character", confidence = "double"
)
.st_ir_results_cols <- names(.st_ir_results_types)

.st_ir_samples_types <- c(
  source_hash = "character", source_ref = "character", work_order = "character",
  org = "character", adapter = "character", lab_sample_id = "character",
  feature_raw = "character", sample_datetime_raw = "character", sample_type = "character",
  parent_sample = "character", matrix_raw = "character", sampler = "character",
  comments = "character", confidence = "double"
)
.st_ir_samples_cols <- names(.st_ir_samples_types)

# Fields required to be non-NA (R-3.1): base set for both kinds, extended
# for results with analyte_raw/value_raw.
.st_ir_required <- list(
  results = c("source_hash", "org", "adapter", "analyte_raw", "value_raw"),
  samples = c("source_hash", "org", "adapter")
)

# Sample_Type vocabulary. QC/lab types (LCS, MB, LAB_D, MS) and NCP are
# non-`Normal`. NCP = "Non-Client Parent" (ESdat spec): another client's field
# sample reported only as the parent of a batch-QC duplicate/spike - dropped by
# assembly (R-7.4) / reconcile (R-8.1), never committed. `unknown` is the ESdat
# chemistry-parser default, later filled by the sample-metadata join.
.st_ir_sample_type_allowed <- c("Normal", "LCS", "MB", "LAB_D", "MS", "NCP", "unknown")

# Zero-length vector of the right type for a prototype column.
.st_ir_empty_col <- function(type) {
  switch(type,
    character = character(0),
    integer = integer(0),
    double = double(0),
    logical = logical(0),
    Date = as.Date(character(0)),
    cli::cli_abort("Unknown IR column type: {type}.", class = "sampletidy_error")
  )
}

.st_ir_prototype <- function(kind) {
  types <- if (kind == "results") .st_ir_results_types else .st_ir_samples_types
  cols <- if (kind == "results") .st_ir_results_cols else .st_ir_samples_cols
  vecs <- lapply(types[cols], .st_ir_empty_col)
  tibble::as_tibble(vecs)
}

#' Construct a validated `results` IR tibble
#'
#' With no arguments, returns the zero-row prototype (DESIGN §4.1): exactly
#' the pinned columns, in order, with the pinned types and no rows. With
#' named arguments (one per column, tibble-constructor style), builds a
#' single (or vectorised) row and validates it via `ir_validate()` (internal).
#'
#' @param ... named column values, one name per `results` column. Omit
#'   entirely for the zero-row prototype.
#' @return a validated tibble with the `results` IR columns.
#' @export
ir_results <- function(...) {
  args <- list(...)
  if (length(args) == 0) {
    out <- .st_ir_prototype("results")
  } else {
    out <- tibble::tibble(!!!args)
  }
  ir_validate(out, "results")
  if (length(args) > 0) {
    out <- out[, .st_ir_results_cols, drop = FALSE]
  }
  out
}

#' Construct a validated `samples` IR tibble
#'
#' With no arguments, returns the zero-row prototype (DESIGN §4.2): exactly
#' the pinned columns, in order, with the pinned types and no rows. With
#' named arguments (one per column, tibble-constructor style), builds a
#' single (or vectorised) row and validates it via `ir_validate()` (internal).
#'
#' @param ... named column values, one name per `samples` column. Omit
#'   entirely for the zero-row prototype.
#' @return a validated tibble with the `samples` IR columns.
#' @export
ir_samples <- function(...) {
  args <- list(...)
  if (length(args) == 0) {
    out <- .st_ir_prototype("samples")
  } else {
    out <- tibble::tibble(!!!args)
  }
  ir_validate(out, "samples")
  if (length(args) > 0) {
    out <- out[, .st_ir_samples_cols, drop = FALSE]
  }
  out
}

#' Validate an IR tibble against the pinned `results`/`samples` shape
#'
#' Aborts (class `sampletidy_ir_error`) naming the offending column(s) on:
#' a missing or extra column, a wrong-typed column, `NA` in a required
#' field (`source_hash`, `org`, `adapter`; for `results` also
#' `analyte_raw`, `value_raw`), a `sample_type` outside the allowed set, or
#' (results only) `revision < 0`.
#'
#' @param x a data frame / tibble to validate.
#' @param kind one of `"results"`, `"samples"`.
#' @return `x`, invisibly, if valid.
#' @keywords internal
#' @noRd
ir_validate <- function(x, kind) {
  checkmate::assert_choice(kind, c("results", "samples"))
  checkmate::assert_data_frame(x)

  cols <- if (kind == "results") .st_ir_results_cols else .st_ir_samples_cols
  types <- if (kind == "results") .st_ir_results_types else .st_ir_samples_types
  required <- .st_ir_required[[kind]]

  missing_cols <- setdiff(cols, names(x))
  if (length(missing_cols) > 0) {
    cli::cli_abort(
      "IR {.val {kind}} validation failed: missing required column{?s}:
       {paste(missing_cols, collapse = ', ')}.",
      class = "sampletidy_ir_error"
    )
  }

  extra_cols <- setdiff(names(x), cols)
  if (length(extra_cols) > 0) {
    cli::cli_abort(
      "IR {.val {kind}} validation failed: unexpected extra column{?s}:
       {paste(extra_cols, collapse = ', ')}.",
      class = "sampletidy_ir_error"
    )
  }

  for (col in cols) {
    type <- types[[col]]
    ok <- switch(type,
      character = is.character(x[[col]]),
      integer = is.integer(x[[col]]),
      double = is.double(x[[col]]),
      logical = is.logical(x[[col]]),
      Date = inherits(x[[col]], "Date"),
      cli::cli_abort("Unknown IR column type: {type}.", class = "sampletidy_error")
    )
    if (!isTRUE(ok)) {
      cli::cli_abort(
        "IR {.val {kind}} validation failed: column {col} has the wrong type
         (expected {type}).",
        class = "sampletidy_ir_error"
      )
    }
  }

  for (col in required) {
    if (nrow(x) > 0 && anyNA(x[[col]])) {
      cli::cli_abort(
        "IR {.val {kind}} validation failed: required column {col} contains NA.",
        class = "sampletidy_ir_error"
      )
    }
  }

  if ("sample_type" %in% names(x) && nrow(x) > 0) {
    st <- x[["sample_type"]]
    bad <- unique(st[!is.na(st) & !(st %in% .st_ir_sample_type_allowed)])
    if (length(bad) > 0) {
      cli::cli_abort(
        "IR {.val {kind}} validation failed: sample_type contains value{?s} not
         in the allowed set ({paste(.st_ir_sample_type_allowed, collapse = ', ')}):
         {paste(bad, collapse = ', ')}.",
        class = "sampletidy_ir_error"
      )
    }
  }

  if (kind == "results" && "revision" %in% names(x) && nrow(x) > 0) {
    rev <- x[["revision"]]
    if (any(!is.na(rev) & rev < 0)) {
      cli::cli_abort(
        "IR {.val {kind}} validation failed: revision must be >= 0.",
        class = "sampletidy_ir_error"
      )
    }
  }

  invisible(x)
}
