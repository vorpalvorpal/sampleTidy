# Small shared test helpers used across the core-test suite (plans 01-03).
# Only DEFINES functions - no top-level calls - so this file can be sourced
# even before any production R/ functions exist.

#' Write a text or binary file into a directory, returning its path
#'
#' Convenience for building tiny file fixtures inline in a test (e.g. for
#' file_meta()/route_files()/ignore_rule() tests) without hand-rolling
#' file.path()/writeLines() boilerplate every time.
#'
#' @param dir directory to write into (typically `withr::local_tempdir()`)
#' @param filename file name (may include a subpath)
#' @param content character vector of lines to write (ignored if `raw` given)
#' @param raw raw vector of bytes to write instead of `content`
#' @return the full path written
st_test_write_file <- function(dir, filename, content = "", raw = NULL) {
  path <- file.path(dir, filename)
  fs::dir_create(dirname(path))
  if (!is.null(raw)) {
    writeBin(raw, path)
  } else {
    writeLines(content, path, useBytes = TRUE)
  }
  path
}

#' Build a small character-matrix "spreadsheet grid" for
#' str_which_df()/vector_from_key() tests
#'
#' Each argument is one row (a character vector); rows are padded with NA to
#' the widest row and stacked into a data.frame of character columns
#' `V1..Vn`, mimicking the shape `readxl::read_excel(col_names = FALSE)`
#' returns for a raw sheet.
#'
#' @param ... row vectors
#' @return a data.frame of character columns
st_test_grid <- function(...) {
  rows <- list(...)
  n_col <- max(lengths(rows))
  rows <- lapply(rows, function(r) {
    length(r) <- n_col
    r
  })
  grid <- as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
  names(grid) <- paste0("V", seq_len(n_col))
  rownames(grid) <- NULL
  grid
}
