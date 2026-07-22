# Plan 03 - R-3.3 adapter registry: register_adapter(), adapter_registry(),
# clear_adapters(). The registry is a package-level environment; adapters
# self-register from .onLoad() in plans 04-06 via register_adapter().

# Package-level adapter registry (env, keyed by adapter id). Not exported;
# access only through register_adapter()/adapter_registry()/clear_adapters().
.st_adapter_registry <- new.env(parent = emptyenv())

#' Register an adapter in the sampleTidy adapter registry
#'
#' Validates the adapter's shape before registering it: `id` and `version`
#' must be single non-empty strings; `match` must be a function taking
#' exactly one argument (`file_meta`); `parse` must be a function taking
#' exactly two arguments (`path`, `file_meta`). Registering a duplicate `id`
#' overwrites the existing registration and emits a `cli::cli_inform()`,
#' unless `quiet = TRUE` (used by `register_builtin_adapters()` for its
#' defensive self-re-registration; a genuine third-party clobber of a
#' built-in id still informs).
#'
#' @param a a list with elements `id`, `version`, `match`, `parse` (DESIGN
#'   §5).
#' @param quiet if `TRUE`, suppress the "Overwriting existing adapter
#'   registration" inform on a duplicate `id`. Default `FALSE`.
#' @return `a`, invisibly.
#' @export
register_adapter <- function(a, quiet = FALSE) {
  checkmate::assert_list(a, names = "unique")

  if (is.null(a$id) || !checkmate::test_string(a$id, min.chars = 1)) {
    cli::cli_abort(
      "Adapter is missing a valid {.field id} (a single non-empty string).",
      class = "sampletidy_error"
    )
  }
  if (is.null(a$version) || !checkmate::test_string(a$version, min.chars = 1)) {
    cli::cli_abort(
      "Adapter {.val {a$id}} is missing a valid {.field version} (a single
       non-empty string).",
      class = "sampletidy_error"
    )
  }
  if (is.null(a$match) || !is.function(a$match) || length(formals(a$match)) != 1) {
    cli::cli_abort(
      "Adapter {.val {a$id}} has an invalid {.field match}: it must be a
       function taking exactly one argument (`file_meta`).",
      class = "sampletidy_error"
    )
  }
  if (is.null(a$parse) || !is.function(a$parse) || length(formals(a$parse)) != 2) {
    cli::cli_abort(
      "Adapter {.val {a$id}} has an invalid {.field parse}: it must be a
       function taking exactly two arguments (`path`, `file_meta`).",
      class = "sampletidy_error"
    )
  }

  if (!quiet && exists(a$id, envir = .st_adapter_registry, inherits = FALSE)) {
    cli::cli_inform("Overwriting existing adapter registration for {.val {a$id}}.")
  }

  assign(a$id, a, envir = .st_adapter_registry)
  invisible(a)
}

#' List all registered adapters
#'
#' @return a named list of adapters, keyed by adapter `id`.
#' @export
adapter_registry <- function() {
  ids <- ls(envir = .st_adapter_registry, sorted = TRUE)
  rlang::set_names(
    lapply(ids, function(id) get(id, envir = .st_adapter_registry, inherits = FALSE)),
    ids
  )
}

#' Empty the adapter registry
#'
#' Used by tests to reset registry state between examples; not part of
#' normal package operation.
#'
#' @return `NULL`, invisibly.
#' @export
clear_adapters <- function() {
  rm(list = ls(envir = .st_adapter_registry, sorted = TRUE), envir = .st_adapter_registry)
  invisible(NULL)
}
