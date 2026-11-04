# PLAN-20 phase 1 (P20.2): session-scoped hooks that inbox_run() fires.
# Spec: dev/plans/PLAN-20-phase1-spec.md.

.hook_events <- c("after_run", "after_status", "work_complete")

# Package-level registry: one (possibly empty, unnamed) list of functions per event.
.hook_env <- new.env(parent = emptyenv())
for (.ev in .hook_events) .hook_env[[.ev]] <- list()
rm(.ev)
# Problems from load_hooks_file(), surfaced in every status afterwards (session state).
.hook_env$file_problems <- character(0)
# Parallel to the function lists: one renderer flag per registered hook.
.hook_env$renderer <- stats::setNames(rep(list(logical(0)), length(.hook_events)), .hook_events)

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
#' twice. The core writes no markdown of its own: a deployment that wants
#' notes registers a renderer for `"after_status"` and `"after_run"`. An error
#' inside a hook never fails [inbox_run()]; it is recorded as a problem in the
#' status, as `hook <event>[<i>] failed: <message>` where `i` is the hook's
#' 1-based registration index within the event.
#'
#' A hook of two or more formals (or one with `...`) is called
#' `fn(arg, context)`; any other is called `fn(arg)`. `context` is a list:
#' `source` (`"inbox_run"`, `"import_status"` or `"import_report"`),
#' `report_dir`, `input_dir` (`NA` for `"import_report"`), `db`, `now`,
#' `timezone`, and `day`. `day` is `NULL` except for `"after_run"`, where it is
#' the day digest (`date`, `time`, `review_items_open` and `runs`, one entry per
#' non-dry-run log line of the local day, each with `started_at`, `time`,
#' `imports`, `filed` and `problems`) when the day has news, else `NULL`.
#'
#' @param event one of `"after_run"` (argument: the list `inbox_run()`
#'   returns), `"after_status"` (the status list written to `status.json`) or
#'   `"work_complete"` (a [completed_work()] tibble of the projects that
#'   became complete during the run).
#' @param fn a function of one argument, or of two to receive the `context`.
#' @param replace_default a single `TRUE` or `FALSE` (default `TRUE`). Ignored:
#'   the core has no default renderers. Kept for one release so that existing
#'   calls still work.
#' @param renderer a single `TRUE` or `FALSE` (default `FALSE`). `TRUE` is
#'   allowed only for `"after_status"` and `"after_run"` and marks the hook as
#'   a renderer, the kind the deprecated [import_status()] and [import_report()]
#'   fire. A renderer fires in [inbox_run()] like any other hook. An `"after_run"`
#'   renderer should do nothing when `context$day` is `NULL`.
#' @return `fn`, invisibly.
#' @export
register_hook <- function(event, fn, replace_default = TRUE, renderer = FALSE) {
  .hook_check_event(event)
  if (!is.function(fn)) {
    cli::cli_abort("{.arg fn} must be a function.", class = "sampletidy_error")
  }
  if (!is.logical(replace_default) || length(replace_default) != 1 ||
      is.na(replace_default)) {
    cli::cli_abort("{.arg replace_default} must be a single {.val TRUE} or {.val FALSE}.",
                   class = "sampletidy_error")
  }
  if (!is.logical(renderer) || length(renderer) != 1 || is.na(renderer)) {
    cli::cli_abort("{.arg renderer} must be a single {.val TRUE} or {.val FALSE}.",
                   class = "sampletidy_error")
  }
  if (renderer && !event %in% c("after_status", "after_run")) {
    cli::cli_abort(
      "{.code renderer = TRUE} is only allowed for {.val after_status} and {.val after_run}.",
      class = "sampletidy_error"
    )
  }
  .hook_env[[event]] <- c(.hook_env[[event]], list(fn))
  .hook_env$renderer[[event]] <- c(.hook_env$renderer[[event]], renderer)
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
    for (ev in .hook_events) .hook_env$renderer[[ev]] <- logical(0)
    .hook_env$file_problems <- character(0)
  } else {
    .hook_check_event(event)
    .hook_env[[event]] <- list()
    .hook_env$renderer[[event]] <- logical(0)
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

# Is a renderer registered for `event`?
.hooks_have_renderer <- function(event) any(.hook_env$renderer[[event]])

# The context every hook can ask for (see register_hook()). `day` is the day
# digest for after_run, else NULL.
.hook_context <- function(source, report_dir, input_dir, db, now, day = NULL) {
  list(source = source, report_dir = report_dir, input_dir = input_dir, db = db,
       now = now, timezone = .st_tz(), day = day)
}

# Does `fn` take the context? A non-primitive with two or more formals, or `...`.
.hook_takes_context <- function(fn) {
  if (is.primitive(fn)) return(FALSE)
  f <- names(formals(fn))
  length(f) >= 2L || "..." %in% f
}

# Run every hook of `event` (only the renderers if `only_renderers`) with `arg`,
# each inside tryCatch, in registration order. Returns the problem strings,
# `hook <event>[<i>] failed: <msg>`, i being the registration index.
.hooks_run <- function(event, arg, context, only_renderers = FALSE) {
  fns <- .hook_env[[event]]
  rend <- .hook_env$renderer[[event]]
  problems <- character(0)
  for (i in seq_along(fns)) {
    if (only_renderers && !isTRUE(rend[[i]])) next
    fn <- fns[[i]]
    msg <- tryCatch({
      if (.hook_takes_context(fn)) fn(arg, context) else fn(arg)
      NULL
    }, error = function(e) conditionMessage(e))
    if (!is.null(msg)) {
      problems <- c(problems, sprintf("hook %s[%d] failed: %s", event, i, msg))
    }
  }
  problems
}
