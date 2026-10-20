# PLAN-20 phase 1 (P20.2): session-scoped hooks that inbox_run() fires.
# Spec: dev/plans/PLAN-20-phase1-spec.md.

.hook_events <- c("after_run", "after_status", "work_complete")

# Package-level registry: one (possibly empty, unnamed) list of functions per event.
.hook_env <- new.env(parent = emptyenv())
for (.ev in .hook_events) .hook_env[[.ev]] <- list()
rm(.ev)

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
#' event's default markdown renderer. An error inside a hook never fails
#' [inbox_run()]; it is recorded as a problem in the status.
#'
#' @param event one of `"after_run"` (argument: the list `inbox_run()`
#'   returns), `"after_status"` (the status list written to `status.json`) or
#'   `"work_complete"` (a [completed_work()] tibble of the projects that
#'   became complete during the run).
#' @param fn a function of one argument.
#' @return `fn`, invisibly.
#' @export
register_hook <- function(event, fn) {
  .hook_check_event(event)
  if (!is.function(fn)) {
    cli::cli_abort("{.arg fn} must be a function.", class = "sampletidy_error")
  }
  .hook_env[[event]] <- c(.hook_env[[event]], list(fn))
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
  } else {
    .hook_check_event(event)
    .hook_env[[event]] <- list()
  }
  invisible(NULL)
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
# registered, `default` (if any) runs in its place with id "default". Returns
# the problem strings, `hook <event>[<id>] failed: <msg>`.
.hooks_run <- function(event, arg, default = NULL) {
  fns <- .hook_env[[event]]
  ids <- seq_along(fns)
  if (length(fns) == 0 && !is.null(default)) {
    fns <- list(default)
    ids <- "default"
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
