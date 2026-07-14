#' Find matching cells in a data frame
#'
#' Generalised, pure-function port of `WEM.data::str_which_df()`: searches
#' every character cell of `df` (coercing all columns to character first) for
#' `pattern` and returns the matching cell coordinates. Used to locate
#' labelled key cells (e.g. `"REPORT NO:"`) in raw, header-free spreadsheet
#' grids such as ACIRL front pages.
#'
#' @param df a data frame (typically read with `col_names = FALSE`, so every
#'   column is character-ish).
#' @param pattern a regular expression to search for in each cell.
#' @param ignore_case should the search be case-insensitive? Default `TRUE`.
#' @param multiple_matches if `FALSE` (default) and more than one cell
#'   matches, aborts (class `sampletidy_error`). If `TRUE`, all matches are
#'   returned.
#' @param squish should each cell be run through [stringr::str_squish()]
#'   before matching (collapses internal whitespace, trims outer)? Default
#'   `TRUE`.
#' @return a [tibble::tibble()] with integer columns `row` and `col`, one row
#'   per matching cell (zero rows if there are no matches).
#' @export
str_which_df <- function(df, pattern, ignore_case = TRUE,
                          multiple_matches = FALSE, squish = TRUE) {
  checkmate::assert_data_frame(df)
  checkmate::assert_string(pattern)
  checkmate::assert_flag(ignore_case)
  checkmate::assert_flag(multiple_matches)
  checkmate::assert_flag(squish)

  char_df <- as.data.frame(lapply(df, as.character), stringsAsFactors = FALSE)
  if (squish) {
    char_df <- as.data.frame(
      lapply(char_df, stringr::str_squish),
      stringsAsFactors = FALSE
    )
  }

  re <- stringr::regex(pattern, ignore_case = ignore_case)
  hits <- purrr::map(seq_len(ncol(char_df)), function(j) {
    row_idx <- which(stringr::str_detect(char_df[[j]], re))
    if (length(row_idx) == 0) {
      return(NULL)
    }
    tibble::tibble(row = row_idx, col = j)
  })
  result <- purrr::list_rbind(purrr::compact(hits))

  if (nrow(result) == 0) {
    return(tibble::tibble(row = integer(0), col = integer(0)))
  }
  result <- result[order(result$col, result$row), ]
  rownames(result) <- NULL

  if (nrow(result) > 1 && !isTRUE(multiple_matches)) {
    cli::cli_abort(
      "Pattern {.val {pattern}} matched {nrow(result)} cells; pass {.code multiple_matches = TRUE} if that's expected.",
      class = "sampletidy_error"
    )
  }

  result
}

#' Extract a vector of cells relative to a labelled key cell
#'
#' Generalised, pure-function port of `WEM.data::vector_from_key()`: finds a
#' single key cell matching `pattern` (via [str_which_df()]) and returns the
#' run of cells extending from it in `direction`, all the way to the edge of
#' the data frame.
#'
#' @param df a data frame (typically read with `col_names = FALSE`).
#' @param pattern a regular expression matching exactly one cell.
#' @param direction one of `"right"`, `"left"`, `"up"`, `"down"`, relative to
#'   the key cell.
#' @param vector_length if given, the length the extracted vector (after
#'   `remove_na`, if set) must have; a mismatch aborts (class
#'   `sampletidy_error`). If `NULL` (default), no length check is performed.
#' @param ignore_case passed to [str_which_df()].
#' @param remove_na drop `NA`s from the extracted vector before the
#'   `vector_length` check? Default `TRUE`.
#' @return a character vector.
#' @export
vector_from_key <- function(df, pattern, direction = "right",
                             vector_length = NULL, ignore_case = TRUE,
                             remove_na = TRUE) {
  checkmate::assert_data_frame(df)
  checkmate::assert_string(pattern)
  checkmate::assert_choice(direction, c("right", "left", "up", "down"))
  checkmate::assert_int(vector_length, lower = 0, null.ok = TRUE)
  checkmate::assert_flag(ignore_case)
  checkmate::assert_flag(remove_na)

  cells <- str_which_df(df, pattern, ignore_case = ignore_case, multiple_matches = FALSE)

  if (nrow(cells) == 0) {
    cli::cli_abort(
      "Pattern {.val {pattern}} did not match any cell.",
      class = "sampletidy_error"
    )
  }

  row <- cells$row[[1]]
  col <- cells$col[[1]]
  n_row <- nrow(df)
  n_col <- ncol(df)

  raw <- switch(direction,
    right = if (col < n_col) unlist(df[row, (col + 1):n_col], use.names = FALSE) else character(0),
    left  = if (col > 1) unlist(df[row, 1:(col - 1)], use.names = FALSE) else character(0),
    down  = if (row < n_row) unlist(df[(row + 1):n_row, col], use.names = FALSE) else character(0),
    up    = if (row > 1) unlist(df[1:(row - 1), col], use.names = FALSE) else character(0)
  )
  raw <- as.character(raw)

  if (remove_na) {
    raw <- raw[!is.na(raw)]
  }

  if (!is.null(vector_length) && length(raw) != vector_length) {
    cli::cli_abort(
      "Vector extracted {.val {direction}} of {.val {pattern}} has length {length(raw)}, expected {vector_length}.",
      class = "sampletidy_error"
    )
  }

  raw
}
