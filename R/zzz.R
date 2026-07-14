# Built-in adapter self-registration (CONTRACT A17/A33). Each adapter plan
# (04/05/06) appends its constructor call to `register_builtin_adapters()`
# as it lands; kept idempotent since `register_adapter()` overwrites an
# existing id rather than erroring. Called from `.onLoad()` AND from the
# start of `ingest_dir()` (plan 09), so a prior `clear_adapters()` (e.g. the
# registry test's deferred cleanup) can never leave the pipeline with no
# adapters.

#' @keywords internal
#' @noRd
register_builtin_adapters <- function() {
  register_adapter(esdat_adapter())
  invisible(NULL)
}

.onLoad <- function(libname, pkgname) {
  register_builtin_adapters()
}
