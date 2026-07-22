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

#' Keys whose value is list/vector-valued rather than scalar.
#'
#' `st_config()` env-var values are always strings (`Sys.getenv()`), which is
#' fine for scalar keys but would silently shrink a list-valued key (e.g.
#' `field_analytes`, an analyte allowlist) to a single-entry vector if read
#' from an env var. Keys named here abort loudly instead when a get would
#' otherwise fall through to the env var - see PLAN-12 R-12.11 (F16).
#'
#' @keywords internal
#' @noRd
.st_config_list_keys <- c("field_analytes")

#' Get or set a sampleTidy configuration value
#'
#' `st_config(key)` reads a configuration value; `st_config(key, value)` sets
#' one. Values are stored as R options under the `sampletidy.<key>` prefix.
#' A get resolves, in order: the option, then the environment variable
#' `SAMPLETIDY_<KEY>` (key upper-cased), then a built-in default. Keys with
#' no built-in default abort if neither the option nor the env var is set.
#'
#' Env-var overrides are string-only: `SAMPLETIDY_<KEY>` always yields a
#' single character value. This is fine for scalar keys (paths,
#' `remove_ingested`, coerced), but a list-valued key such as
#' `field_analytes` cannot be safely sourced from an env var - a single
#' string would silently shrink the allowlist to one entry. For the known
#' list-valued keys, `st_config()` aborts if it would otherwise fall through
#' to the env var; set such a key in code via `st_config(key, value)`
#' instead (see PLAN-12 R-12.11).
#'
#' @param key configuration key, e.g. `"live_db"`, `"input_dir"`.
#' @param value if supplied, the value to set for `key`.
#' @return the resolved value (get), or `value` invisibly (set).
#' @export
st_config <- function(key, value) {
  checkmate::assert_string(key)
  option_name <- paste0("sampletidy.", key)

  if (!missing(value)) {
    opts <- rlang::set_names(list(value), option_name)
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
    if (key %in% .st_config_list_keys) {
      cli::cli_abort(
        "Config key {.val {key}} is list-valued and cannot be sourced from
         env var {.val {env_var}} (env vars are always a single string,
         which would silently shrink it to one entry). Set it in code
         instead: {.code st_config({.val {key}}, c(...))}.",
        class = "sampletidy_error"
      )
    }
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
