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
  # A76 (Robin, 2026-08-01): the field set is MAXIMAL. Every entry below is
  # matched exactly (after `str_squish()` + upper-case) against an ACIRL water
  # sheet's parameter label. The list is grounded in two measurements, not in
  # the analyte names of the ruling:
  #
  #   (a) a label census over the real corpus (156 workbooks, 13768 label rows,
  #       296 distinct labels - `scratchpad/a76_label_counts.csv`), and
  #   (b) the 32 `lab_method` rows already carrying `method = 'field'`, whose
  #       `name` column IS the ACIRL sheet label ("Electrical Conductivity",
  #       "Water Depth", "Flow observation", ...).
  #
  # Deliberately NOT here:
  #   * "Electrical Conductivity @ 25<degC>" - that is the ALS value transcribed
  #     into the sheet, not a field reading. ACIRL used to own a `field`
  #     lab_method under the MOJIBAKE spelling of that label with zero analyses;
  #     it was deleted from the live database on 2026-08-01 (change_log
  #     uuid_row 9f59b10a). The clean-named row is correct and untouched: org
  #     ALS, method "EA010P: Conductivity by PC Titrator". Either way the label
  #     must never be allowlisted.
  #   * the TSS pair - see `acirl_transcription_labels` below.
  # Observation labels are not here either: they take the qualitative
  # Stage/Appearance path in the ACIRL adapter, not the allowlist.
  field_analytes = function() {
    c(
      # Present in the corpus AND registered as ACIRL `field` lab_methods.
      "pH", "Temperature", "Electrical Conductivity",
      # The six standing-water-level name variants, preserved as received
      # (A76): each is its own registered lab_method against the single
      # `Standing water level` analyte.
      "Standing Water Level", "Standing Water Height", "Standing water level",
      "Water Height", "Water Depth",
      # Registered ACIRL `field` methods with ZERO occurrences in the
      # 2026-08-01 corpus. Allowlisted so a future sheet is imported rather
      # than routed to review; they cost nothing while absent.
      "DO", "ORP", "CH4 Reading % v/v", "H2S Reading % v/v",
      # A76 ruled turbidity in. It has no analyte, no lab_method and zero
      # corpus occurrences - until the `Turbidity` analyte is created it will
      # resolve to `analyte_pending` and surface in review, which is the
      # correct failure mode.
      "Turbidity",
      # Retained from the original pinned default. Neither occurs as a
      # standalone label in the real corpus; both are registered `field`
      # methods for the `legacy`/`Internal` organisations.
      "Conductivity", "EC"
    )
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
  #     permutations of ALS's numbers (B.S01/B.S03 hold each other's values,
  #     B.MW08/B.MW11 likewise), i.e. copy errors, not measurements.
  #
  # TSS is gravimetric (filter, dry at 104C, weigh), so the method implies it
  # too. ACIRL's two `field` TSS lab_methods asserted the opposite; both carried
  # ZERO analyses and were deleted from the live database on 2026-08-02
  # (change_log uuid_row 29cfea72, c8b85ce2) on Robin's ruling. So the name can
  # no longer resolve to a field method at all - this list is the belt to that
  # braces, keeping the label out of the allowlist path even if someone later
  # adds it there.
  acirl_transcription_labels = function() {
    c("Total Suspended Solids", "Suspended Solids (SS)", "TSS")
  },
  # TRUE since 2026-07-23 (Robin): a successfully ingested source file is
  # deleted from the input directory once its archive copy has been verified.
  # Supersedes the original A13 default of FALSE. The safety property A13
  # actually cares about is unchanged and in fact strengthened - see
  # `.ig_remove_verified()`, which now requires the archived bytes to re-hash
  # to the source's content hash, not merely to exist. Removal additionally
  # requires a successful snapshot (`R/ingest.R`).
  remove_ingested = function() {
    TRUE
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
.st_config_list_keys <- c("field_analytes", "acirl_transcription_labels")

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
