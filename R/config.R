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
  # `field_analytes` (character vector, default none): the ACIRL water-sheet
  # parameter labels that are field readings. The ACIRL field adapter matches
  # each entry exactly, after `str_squish()` + upper-case; a labelled row with
  # a value whose label is not listed goes to `report$als_candidates` and is
  # skipped as `lab_data_dropped`. Observation labels do not need listing:
  # they take the qualitative Stage/Appearance path. A deployment sets it, so
  # an unconfigured install imports no field readings from a water sheet.
  field_analytes = function() {
    character(0)
  },
  # Labels that share their name with the ALS analyte, so the allowlist alone
  # cannot tell an ACIRL reading from a transcribed ALS result. They are NEVER
  # imported on the strength of the name; the adapter routes them to
  # `report$als_candidates`.
  #
  # This was `field_analytes_diff_required` until 2026-08-02, when A75's value
  # comparison - the mechanism that was supposed to promote one of them to a
  # field result - was replaced by A79 and the question was settled by
  # measurement instead. Every ACIRL `Total Suspended Solids` row in the corpus
  # is a TRANSCRIPTION, not a field estimate:
  #
  #   * 284 of 678 are written `<5`, and `<5` is the only `<` value present.
  #     ALS's TSS method (EA025) has rl_low = 5 and 345 of its recorded
  #     non-detects sit at exactly that limit. A field estimate cannot produce
  #     a laboratory reporting limit, let alone ALS's.
  #   * of the 362 comparable against an ALS TSS row at the same work order and
  #     feature, 355 (98.1%) are IDENTICAL - and the 7 that differ are
  #     permutations of ALS's numbers (N.S01/N.S03 hold each other's values,
  #     N.MW08/N.MW11 likewise), i.e. copy errors, not measurements.
  #
  # TSS is gravimetric (filter, dry at 104C, weigh), so the method implies it
  # too. ACIRL's two `field` TSS lab_methods asserted the opposite; both carried
  # ZERO analyses and were deleted from the live database on 2026-08-02
  # (change_log uuid_row 29cfea72, c8b85ce2) on the ruling. So the name can
  # no longer resolve to a field method at all - this list is the belt to that
  # braces, keeping the label out of the allowlist path even if someone later
  # adds it there.
  acirl_transcription_labels = function() {
    c("Total Suspended Solids", "Suspended Solids (SS)", "TSS")
  },
  # TRUE since 2026-07-23: a successfully ingested source file is
  # deleted from the input directory once its archive copy has been verified.
  # Supersedes the original A13 default of FALSE. The safety property A13
  # actually cares about is unchanged and in fact strengthened - see
  # `.ig_remove_verified()`, which now requires the archived bytes to re-hash
  # to the source's content hash, not merely to exist. Removal additionally
  # requires a successful snapshot (`R/ingest.R`).
  remove_ingested = function() {
    TRUE
  },
  # Archive settling (`archive_settle()`, R/archive.R): NULL = off. A list
  # turns it on - fields `ext`, `hold_secs`, `window_hours`, `accept`, each
  # defaulted and validated by `.ar_settle_config()`. List-valued, so it
  # cannot come from an env var (see `.st_config_list_keys`).
  archive_settle = function() {
    NULL
  },
  # Extra content fingerprinters (`content_fingerprint()`,
  # R/content-fingerprint.R): NULL = the built-in `ole1` only. A named list
  # of `list(magic = <raw>, fun = function(path))`, validated by
  # `.cf_registry()`. List-valued, so no env var.
  content_fingerprinters = function() {
    NULL
  },
  # The time zone of "local" calendar days: sample dates, "today" in the
  # flags, report and status stamps. Read at call time via `.st_tz()`, which
  # validates it against `OlsonNames()`. The default is UTC; a deployment
  # sets its own zone.
  timezone = function() {
    "UTC"
  },
  # `checks` (NULL, a list or a zero-argument function returning a list) is
  # what a deployment's job passes as `inbox_run(checks = )`; see
  # `import_flags()` for its elements. `site_keywords` (NULL or a
  # named list mapping a site code to keywords) lets the ACIRL gas adapter
  # infer the site from a workbook's own text. Both are list-valued.
  checks = function() {
    NULL
  },
  site_keywords = function() {
    NULL
  },
  # `inbox_batches` (NULL or an `inbox_batches()` object) says which folders of
  # the input directory are batches, how long they settle and what happens to
  # their leftovers; NULL means the generic recogniser, `inbox_batches()`.
  inbox_batches = function() {
    NULL
  },
  # The directory the auto-import job keeps its status note, logs, lock and
  # gate in (`dev/auto-import.R`). A deployment sets SAMPLETIDY_REPORT_DIR.
  report_dir = function() {
    file.path(tools::R_user_dir("sampleTidy", "data"), "reports")
  },
  # `gas_template_slots` (NULL or a character vector of feature names): names
  # the lab's gas template prints at a site that has no such probe; see
  # `.st_gas_template_slots()`. List-valued, so no env var.
  gas_template_slots = function() {
    NULL
  },
  # `acirl_job_prefix` (NULL or one string of 1-8 ASCII digits): the job prefix
  # that makes a filename ACIRL-shaped; see `.ig_acirl_prefix()`. NULL means
  # no prefix is configured and no name is ACIRL-shaped. A deployment sets it
  # (or SAMPLETIDY_ACIRL_JOB_PREFIX).
  acirl_job_prefix = function() {
    NULL
  },
  # `writer_check` (NULL or a function of the database path): asked at the top
  # of `inbox_run()` whether this machine may write the database now; see
  # `.ib_writer_check()`. NULL means always allowed. A function, so no env var.
  writer_check = function() {
    NULL
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
.st_config_list_keys <- c("field_analytes", "acirl_transcription_labels", "archive_settle",
                          "content_fingerprinters", "checks", "site_keywords", "inbox_batches", "gas_template_slots",
                          "writer_check")

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
#' `archive_settle` is one such list-valued key: `NULL` (the default) turns
#' archive settling off, and a list such as `list()` or
#' `list(ext = "xls", hold_secs = 600)` turns it on. See [archive_settle()]
#' for its fields.
#'
#' `content_fingerprinters` is another: `NULL` (the default) uses only the
#' built-in `ole1` fingerprinter, and a named list of
#' `list(magic = <raw>, fun = function(path))` adds more. See
#' [content_fingerprint()].
#'
#' `timezone` is the time zone of local calendar days (default `"UTC"`);
#' it must be one string in [OlsonNames()]. `checks`, `site_keywords` and
#' `inbox_batches` are list-valued keys, `NULL` by default: `checks` is what a
#' deployment's job passes to [inbox_run()] for its import flags (a list, or a zero-argument
#' function returning one), and `site_keywords` maps a site code to the
#' keywords by which the gas adapter recognises that site in a workbook.
#' `inbox_batches` is `NULL` or an [inbox_batches()] object: which folders of
#' the input directory [inbox_run()] treats as batches, how long they settle and
#' what happens to the files an import leaves behind. `NULL` means
#' `inbox_batches()`: every non-hidden subfolder, settled at once, left in place.
#'
#' `report_dir` is the directory the auto-import job keeps its status note, logs,
#' lock and gate in (default: a `reports` folder under `tools::R_user_dir("sampleTidy", "data")`;
#' a deployment sets `SAMPLETIDY_REPORT_DIR`). `gas_template_slots` is `NULL`
#' or a character vector of feature names that the lab's gas template prints
#' at a site that has no such probe: the gas adapter skips a numeric reading
#' at one as `template_slot`. It is list-valued, so it cannot come from an
#' env var.
#'
#' `acirl_job_prefix` is `NULL` (the default) or one string of 1-8 ASCII
#' digits, the job prefix that makes a filename ACIRL-shaped (`<prefix>-NNNN`).
#' With no prefix configured no name is ACIRL-shaped. It may come from the
#' env var `SAMPLETIDY_ACIRL_JOB_PREFIX`; any other value aborts where it is used.
#'
#' `field_analytes` is a character vector (default `character(0)`) of the
#' field-sheet labels that are field readings: the ACIRL field adapter imports
#' a water-sheet row as a result only if its label, after squishing white
#' space and upper-casing, matches an entry. With the default no field reading
#' is imported. It is list-valued, so it cannot come from an env var, and a
#' value that is not a character vector without `NA` aborts where it is used.
#'
#' `writer_check` is `NULL` (the default: every run may write) or a function
#' that [inbox_run()] calls first, as `fn(db)`, before it touches the
#' database. Exactly `TRUE` allows the run; anything else refuses it, and the
#' run imports nothing (see [inbox_run()]). Like `checks`, it is set in code,
#' never from an env var.
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

#' Which optional configuration features this version of sampleTidy has
#'
#' A deployment's hooks file can test for these names before setting the
#' matching [st_config()] keys, so that it still loads under an older
#' sampleTidy.
#'
#' @return a character vector of capability names.
#' @export
st_capabilities <- function() {
  c("timezone", "checks_option", "checks_streams", "site_names",
    "site_keywords", "date_overrides_env", "inbox_batches", "renderer_hooks",
    "report_dir", "gas_template_slots", "acirl_job_prefix", "field_analytes",
    "writer_check")
}

# Validated zones, memoised per value (OlsonNames() is slow-ish).
.st_tz_ok <- new.env(parent = emptyenv())

#' The configured time zone, validated
#'
#' Read at call time, never cached in a constant. Aborts unless the value is
#' one string in `OlsonNames()`; the result is therefore safe to embed in SQL.
#' @keywords internal
#' @noRd
.st_tz <- function(tz = st_config("timezone")) {
  .st_check_tz(tz, "st_config(\"timezone\")")
}

.st_check_tz <- function(tz, what = "time zone") {
  if (is.character(tz) && length(tz) == 1L && !is.na(tz) && nzchar(tz) &&
      !is.null(.st_tz_ok[[tz]])) {
    return(tz)
  }
  if (!is.character(tz) || length(tz) != 1L || is.na(tz) || !nzchar(tz) ||
      !tz %in% OlsonNames()) {
    cli::cli_abort(
      c("{what} must be one time zone name from {.code OlsonNames()}.",
        x = "Got {.val {if (is.character(tz) && length(tz) == 1L) tz else class(tz)}}."),
      class = "sampletidy_error"
    )
  }
  assign(tz, TRUE, envir = .st_tz_ok)
  tz
}
