# Plan 01 - R-1.2 hash_file(): SHA-256 of file contents (A5).

#' Hash a file's contents with SHA-256
#'
#' Content-only hash (A5): two files with identical bytes hash equal
#' regardless of filename or mtime. Used as the identity key for
#' `ingest_file` and for asset provenance.
#'
#' @param path path to an existing, readable file.
#' @return a lower-case hex SHA-256 digest string.
#' @keywords internal
#' @noRd
hash_file <- function(path) {
  checkmate::assert_string(path)
  if (!fs::file_exists(path)) {
    cli::cli_abort(
      "Cannot hash file: {.path {path}} does not exist.",
      class = "sampletidy_error"
    )
  }
  digest::digest(path, file = TRUE, algo = "sha256")
}
