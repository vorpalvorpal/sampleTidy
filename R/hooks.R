# PLAN-20 phase 1 (P20.2): session-scoped hooks that inbox_run() fires.
# Spec: dev/plans/PLAN-20-phase1-spec.md.

.hook_events <- c("after_run", "after_status", "work_complete")

# Package-level registry: one (possibly empty, unnamed) list of functions per event.
.hook_env <- new.env(parent = emptyenv())
for (.ev in .hook_events) .hook_env[[.ev]] <- list()
rm(.ev)
# Problems from load_hooks_file(), surfaced in every status afterwards (session state).
.hook_env$file_problems <- character(0)
# Parallel to the function lists: one replace_default flag per registered hook.
.hook_env$replace <- stats::setNames(rep(list(logical(0)), length(.hook_events)), .hook_events)

.hook_check_event <- function(event) {
  if (!is.character(event) || length(event) != 1 || is.na(event) ||
      !event %in% .hook_events) {
    cli::cli_abort(
      "{.arg event} must be one of {.val {(.hook_events)}}.",
      class = "sampletidy_error"
    )
  }
  invisible(event)
}

#' Register a hook that `inbox_run()` fires
#'
#' Hooks are session state (not persisted). Hooks of one event run in
#' registration order; the same function may be registered twice and then runs
#' twice. Registering a hook for `"after_status"` or `"after_run"` replaces that
#' event's default markdown renderer, unless every hook registered for the event
#' has `replace_default = FALSE`: then the default runs first and the hooks run
#' after it, in registration order. An error inside a hook never fails
#' [inbox_run()]; it is recorded as a problem in the status.
#'
#' @param event one of `"after_run"` (argument: the list `inbox_run()`
#'   returns), `"after_status"` (the status list written to `status.json`) or
#'   `"work_complete"` (a [completed_work()] tibble of the projects that
#'   became complete during the run).
#' @param fn a function of one argument.
#' @param replace_default a single `TRUE` or `FALSE` (default `TRUE`). The
#'   event's default renderer is suppressed if at least one hook registered for
#'   the event has `replace_default = TRUE`. Has no effect for `"work_complete"`,
#'   which has no default.
#' @return `fn`, invisibly.
#' @export
register_hook <- function(event, fn, replace_default = TRUE) {
  .hook_check_event(event)
  if (!is.function(fn)) {
    cli::cli_abort("{.arg fn} must be a function.", class = "sampletidy_error")
  }
  if (!is.logical(replace_default) || length(replace_default) != 1 ||
      is.na(replace_default)) {
    cli::cli_abort("{.arg replace_default} must be a single {.val TRUE} or {.val FALSE}.",
                   class = "sampletidy_error")
  }
  .hook_env[[event]] <- c(.hook_env[[event]], list(fn))
  .hook_env$replace[[event]] <- c(.hook_env$replace[[event]], replace_default)
  invisible(fn)
}

#' Clear registered hooks
#'
#' @param event `NULL` (every event) or one event name.
#' @return `NULL`, invisibly.
#' @export
clear_hooks <- function(event = NULL) {
  if (is.null(event)) {
    for (ev in .hook_events) .hook_env[[ev]] <- list()
    for (ev in .hook_events) .hook_env$replace[[ev]] <- logical(0)
    .hook_env$file_problems <- character(0)
  } else {
    .hook_check_event(event)
    .hook_env[[event]] <- list()
    .hook_env$replace[[event]] <- logical(0)
  }
  invisible(NULL)
}

#' Load a site hooks file
#'
#' Sources `path` into a new environment whose parent is [globalenv()], so the
#' file can call [register_hook()] unqualified and a registered closure keeps
#' the helpers the file defines. Call it after the package is loaded and before
#' [inbox_run()]; `dev/auto-import.R` does, so a deployment sets the
#' `SAMPLETIDY_HOOKS_FILE` environment variable to attach its hooks.
#'
#' It never errors. A missing file or a file that fails to source is recorded
#' as session state and appears in the Problems of every status [inbox_run()]
#' writes afterwards (after the log-derived problems, before the run's own hook
#' failures); it is not a run error. Each call replaces the recorded problems,
#' and `clear_hooks()` with no argument clears them.
#'
#' @param path the hooks file; `""` (the default when the variable is unset) is
#'   a no-op.
#' @return The problem as a string, or `character(0)`; invisibly.
#' @export
load_hooks_file <- function(path = Sys.getenv("SAMPLETIDY_HOOKS_FILE")) {
  problem <- character(0)
  if (length(path) == 1 && !is.na(path) && nzchar(path)) {
    if (!file.exists(path)) {
      problem <- sprintf("hooks file %s not found", path)
    } else {
      msg <- tryCatch({
        sys.source(path, envir = new.env(parent = globalenv()), keep.source = FALSE)
        NULL
      }, error = function(e) conditionMessage(e))
      if (!is.null(msg)) problem <- sprintf("hooks file %s failed: %s", path, msg)
    }
  }
  .hook_env$file_problems <- problem
  invisible(problem)
}

#' List registered hooks
#'
#' @param event `NULL` (all events) or one event name.
#' @return With `NULL`, a named list (`after_run`, `after_status`,
#'   `work_complete`) of lists of functions; with an event name, that event's
#'   list of functions.
#' @export
hooks <- function(event = NULL) {
  if (is.null(event)) {
    return(stats::setNames(lapply(.hook_events, function(ev) .hook_env[[ev]]), .hook_events))
  }
  .hook_check_event(event)
  .hook_env[[event]]
}

# Run every hook of `event` with `arg`, each inside tryCatch. With no hook
# registered, or none has replace_default = TRUE, `default` (if any) runs first
# with id "default"; then the hooks, in registration order. Returns
# the problem strings, `hook <event>[<id>] failed: <msg>`.
.hooks_run <- function(event, arg, default = NULL) {
  fns <- .hook_env[[event]]
  ids <- seq_along(fns)
  if (!is.null(default) && !any(.hook_env$replace[[event]])) {
    fns <- c(list(default), fns)
    ids <- c("default", ids)
  }
  problems <- character(0)
  for (i in seq_along(fns)) {
    fn <- fns[[i]]
    msg <- tryCatch({
      fn(arg)
      NULL
    }, error = function(e) conditionMessage(e))
    if (!is.null(msg)) {
      problems <- c(problems, sprintf("hook %s[%s] failed: %s", event, ids[[i]], msg))
    }
  }
  problems
}
