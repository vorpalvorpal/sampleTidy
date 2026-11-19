#' DuckDB connection configuration
#'
#' Returns the `config` list passed to every DuckDB connection the package
#' opens. DuckDB's own default memory limit is 80% of RAM, which can exhaust a
#' small machine, so sampleTidy caps it.
#'
#' The limit is taken from, in order:
#' 1. the option `sampleTidy.duckdb_memory_limit`;
#' 2. the environment variable `SAMPLETIDY_DUCKDB_MEMORY_LIMIT` (empty means
#'    unset);
#' 3. the default, `"2GB"`.
#'
#' The value `"none"` (any case) means no cap: `memory_limit` is omitted and
#' DuckDB uses its own default.
#'
#' @return a named list for the `config` argument of
#'   `DBI::dbConnect(duckdb::duckdb(), ...)`; empty when the limit is `"none"`.
#' @export
#' @examples
#' st_duckdb_config()
#' withr::with_options(
#'   list(sampleTidy.duckdb_memory_limit = "none"),
#'   st_duckdb_config()
#' )
st_duckdb_config <- function() {
  limit <- getOption("sampleTidy.duckdb_memory_limit")
  if (is.null(limit) || !nzchar(limit)) {
    limit <- Sys.getenv("SAMPLETIDY_DUCKDB_MEMORY_LIMIT", unset = "")
  }
  if (!nzchar(limit)) limit <- "2GB"
  if (tolower(trimws(limit)) == "none") return(list())
  list(memory_limit = limit)
}
