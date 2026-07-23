# Plan 01 - R-1.2 hash_file(): xxHash128 of file contents (A5).

#' Hash a file's contents with xxHash128
#'
#' Content-only hash (A5): two files with identical bytes hash equal
#' regardless of filename or mtime. Used as the identity key for
#' `ingest_file` and for asset provenance.
#'
#' **Algorithm changed 2026-07-23 (Robin): SHA-256 -> xxHash128**, i.e.
#' `rlang::hash_file()`, a 32-character lower-case hex digest. The reason is
#' interoperability with the data already in the registry: the pre-package
#' system (`~/Desktop/WEM.data`, `R/new/import/import_dust.R` and
#' `R/shiny/app.R`) wrote `rlang::hash_file()` into `asset.hash`, so 2,407 of
#' the 2,433 hashed asset rows are xxHash128 and only the 26 written by
#' sampleTidy were SHA-256. Converging on the majority algorithm makes the
#' whole table verifiable with one function; keeping SHA-256 would have left
#' 99% of the archive permanently uncheckable. Stored SHA-256 values were
#' migrated in the same change - see PLAN-CHANGE-REQUESTS.md.
#'
#' Note this is a NON-cryptographic hash. That is appropriate here: the hash is
#' a content-addressing and de-duplication key for lab deliverables, not a
#' defence against an adversary who can choose file contents. Do not reuse it
#' for tamper-evidence.
#'
#' @param path path to an existing, readable file.
#' @return a lower-case hex xxHash128 digest string (32 characters).
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
  rlang::hash_file(path)
}
