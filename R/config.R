# Plan 01 - R-1.1 st_config(): package configuration, options-backed.
#
# Resolution order for a get: option (`sampletidy.<key>`) > env var
# (`SAMPLETIDY_<KEY>`) > built-in default. A set (`st_config(key, value)`)
# always writes the option.

#' Built-in defaults for `st_config()` keys.
#'
#' Each entry is a zero-arg function so defaults that depend on the current
#' environment (e.g. `corpus_dir`) are computed at call time, not at package
#' load time. Keys with no entry here have no default: `st_config()` aborts
#' if neither an option nor an env var is set for them (`input_dir`,
#' `archive_dir`, `snapshot_dir`).
#'
#' @keywords internal
#' @noRd
.st_config_defaults <- list(
  live_db = function() {
    file.path(tools::R_user_dir("sampleTidy", "data"), "monitoring.duckdb")
  },
  field_analytes = function() {
    c("pH", "Temperature", "Conductivity", "EC")
  },
  remove_ingested = function() {
    FALSE
  },
  # Deliberately reads SAMPLETIDY_CORPUS (not the SAMPLETIDY_CORPUS_DIR
  # pattern used for the option/env-var lookup below) - see PLAN-01 R-1.1.
  corpus_dir = function() {
    Sys.getenv("SAMPLETIDY_CORPUS", "")
  }
)

#' Get or set a sampleTidy configuration value
#'
#' `st_config(key)` reads a configuration value; `st_config(key, value)` sets
#' one. Values are stored as R options under the `sampletidy.<key>` prefix.
#' A get resolves, in order: the option, then the environment variable
#' `SAMPLETIDY_<KEY>` (key upper-cased), then a built-in default. Keys with
#' no built-in default abort if neither the option nor the env var is set.
#'
#' @param key configuration key, e.g. `"live_db"`, `"input_dir"`.
#' @param value if supplied, the value to set for `key`.
#' @return the resolved value (get), or `value` invisibly (set).
#' @export
st_config <- function(key, value) {
  checkmate::assert_string(key)
  option_name <- paste0("sampletidy.", key)

  if (!missing(value)) {
    opts <- stats::setNames(list(value), option_name)
    options(opts)
    return(invisible(value))
  }

  opt_val <- getOption(option_name)
  if (!is.null(opt_val)) {
    return(opt_val)
  }

  env_var <- paste0("SAMPLETIDY_", toupper(key))
  env_val <- Sys.getenv(env_var, unset = NA_character_)
  if (!is.na(env_val)) {
    return(env_val)
  }

  default_fn <- .st_config_defaults[[key]]
  if (!is.null(default_fn)) {
    return(default_fn())
  }

  cli::cli_abort(
    "No value is set for config key {.val {key}} (checked option
     {.val {option_name}} and env var {.val {env_var}}), and it has no
     built-in default.",
    class = "sampletidy_error"
  )
}
