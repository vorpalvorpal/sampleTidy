# A75/A79 (step 5) - operator-run migration: give the 5 reporting views a
# CANONICAL-ROW marker, so a consumer asking for pH gets one answer instead of
# two silently-equal ones.
#
# THE DEFECT (live today, independent of any ACIRL import). `v_measurement`
# applies no preference at all - it is a flat join, and where a sampling visit
# produced BOTH a field reading and a lab reading it returns both rows with
# nothing saying which is canonical. Measured on the live DB (2026-08-02,
# scratchpad/m005_partition_probe.R): 931 (feature, Sydney date, analyte)
# partitions carry both, 1,903 rows in total - pH 560 field / 541 lab, EC 406
# field / 396 lab, and nothing else. The two are genuinely DIFFERENT
# measurements (the sample degasses and re-equilibrates before the lab sees
# it), so the fix is a ranking, never a delete.
#
# THE RULE (Robin, 2026-08-02): field beats lab; among lab, ALS beats ACIRL.
#
#     ORDER BY is_field DESC,                  -- field beats lab
#              (organisation = 'ALS') DESC      -- among lab, ALS beats ACIRL
#
# WHAT THIS MIGRATION ADDS, and what it deliberately does NOT do. Every view
# gains two columns - `is_field` and `preference_rank` (1 = canonical) - and
# NOT ONE ROW IS DROPPED. Three reasons, in order of weight:
#
#   1. `v_measurement*` has no in-repo consumer (`dev/epa-monitoring-report.R`
#      builds its own base query and says so at its assumption C). The only
#      consumers are external, and this migration cannot see them. Adding a
#      column is additive for every one of them; dropping 2,471 rows from
#      `v_measurement` would silently change an answer some spreadsheet is
#      already producing.
#   2. Both rows are real data. The out-ranked lab pH is not wrong - it is a
#      lab pH. A consumer comparing field to lab must still be able to.
#   3. Row-count preservation is what makes the verify gate strong: this
#      migration can assert every view's cardinality is IDENTICAL to the
#      independent base-table oracle 004 already established, so "the window
#      function changed the result set" is a hard failure rather than an
#      expected difference the gate would have to be loosened to accommodate.
#
# Consumers opt in with `WHERE preference_rank = 1`. On the live DB that
# returns 94,647 of `v_measurement`'s 97,118 rows, out-ranking 2,471.
#
# THAT 2,471 IS NOT THE 931/972 FIELD-VS-LAB FIGURE, and conflating the two is
# the easiest mistake to make about this migration. `preference_rank > 1`
# counts EVERY partition holding more than one row, whatever the reason.
# Measured on a copy of the live DB (scratchpad/m6a_972.R), it decomposes
# exactly:
#
#     field vs lab            931 partitions, 1,903 rows ->   972 out-ranked
#     two or more LAB rows    706 partitions, 2,166 rows -> 1,460 out-ranked
#     two or more FIELD rows   39 partitions,    78 rows ->    39 out-ranked
#                                                          -------
#                                                            2,471
#
# The 1,460 were never counted before because the design question was only ever
# about field-vs-lab. They are duplicate LAB analyses of one analyte at one
# feature on one Sydney date - 494 of the 706 partitions hold DIFFERENT values -
# and `is_field`/`is_als` cannot separate them, so they fall to the tiebreak.
# That is what makes the sample key below load-bearing rather than cosmetic.
#
# THREE THINGS MEASUREMENT SETTLED THAT REASONING HAD NOT (all in
# scratchpad/m005_partition_probe.R; each would have shipped a defect):
#
#   (a) PARTITION BY DATE, NOT DATETIME. The design as recorded said "per
#       (feature, datetime, analyte)". Measured, that key finds only 916 of the
#       931 contested partitions: 54 of them have the field row and the lab row
#       at different datetimes on the same day (the observed shape is a field
#       reading at 00:00 and its lab twin at 00:01 - one visit, two clocks).
#       Keyed on datetime those become partitions of one and rank 1 each, so
#       the ranking silently does nothing for exactly the rows a human would
#       most expect it to. The partition key is the SYDNEY CALENDAR DATE - the
#       same expression 004 established for the `date` projection, reused
#       verbatim from one constant so the two can never drift.
#   (b) THE ORDER BY DOES NOT BREAK EVERY TIE. 74 partitions hold TWO field
#       rows. `is_field DESC, is_als DESC` leaves those two indistinguishable,
#       so `preference_rank` would be nondeterministic - a consumer could get a
#       different "canonical" pH on two runs of the same query, which is worse
#       than the ambiguity this migration exists to remove. `s.uuid, a.uuid`
#       are appended as a total, stable tiebreak. Arbitrary, but the same
#       arbitrary answer every time, which is the property that matters.
#       THE SAMPLE KEY COMES FIRST, and that was found by measuring the ranked
#       output rather than by reasoning about it (scratchpad/m6a_frankenstein.R):
#       with `a.uuid` alone the last tiebreak is the ANALYSIS uuid, which bears
#       no relation to the sample, so on a feature/date where two distinct
#       samples were both analysed `preference_rank = 1` selected a DIFFERENT
#       sample per analyte. 62 feature/date groups did exactly that. The dust
#       triple at B.D07 on 2021-08-01 is the clearest: rank 1 took combustible
#       from one gauge and incombustible and total from the other, so the
#       canonical rows read 0.6 + 2.2 against a total of 4.2, while within
#       either sample the triple sums. Ordering on the sample first makes every
#       analyte in a feature/date agree on which sample wins; it cannot affect
#       field-vs-lab, where `is_field DESC` already decides.
#   (c) `lm.method IN (...)` IS NULL, NOT FALSE, FOR A NULL METHOD, and 3,170
#       analyses sit on a NULL-method lab_method. Under DuckDB's NULLS LAST
#       default a bare `(lm.method = 'field') DESC` would rank them last, which
#       LOOKS right and is right by accident - it would silently invert the
#       moment the ordering direction changed. Both ordering keys are
#       COALESCEd to FALSE explicitly. This is the same NA trap that poisoned
#       the first run of the probe itself.
#
# The field-method list is NOT re-derived here - it is read from
# `.RC_FIELD_METHODS` (R/reconcile.R), the same constant R-8.9's supersession
# test uses, so the views and the import rule cannot disagree about whether
# `EN67 - Client Supplied Data` is a field reading. (It is: A75 records that
# ALS sometimes carries the field reading itself.)
#
# NEVER invoked by package code (A50) - an operator runs it directly, from an R
# session where the sampleTidy PACKAGE HAS ALREADY BEEN LOADED VIA
# `devtools::load_all(".")` (Robin's ruling 4, Phase 7b round 3, 2026-07-26).
# REQUIRED, not merely convenient, and MORE so here than for 004: as well as
# `st_connect()` / `db_transaction()` / `with_db_write()`, this file reads the
# internal constant `.RC_FIELD_METHODS`, invisible to an unqualified lookup
# once this file is `sys.source()`d against a merely-INSTALLED package. See
# 004-view-repair.R's header for the full reproduction.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/005-preference-rank.R", envir = env)
#   env$mig005_run(db = "/path/to/monitoring.duckdb",
#                  snapshot_dir = "/path/to/snapshots", dry_run = TRUE)
#
# Depends on 004-view-repair.R having already run against `db` (005 rebuilds
# 004's OWN views and keeps every column 004 restored; running it against a
# pre-004 DB would silently re-gut the projection). Enforced by the 1004
# marker check in step 0.
#
# Pure view DDL - no base-table row is read, written or logged, so there is no
# `change_log` entry to write (004's own reasoning, and 001's before it). The
# verify gate has the same TWO halves 004 established, for the same reason:
# `mig005_verify()` proves the SAFETY property (base tables byte-identical),
# `.mig005_verify_views()` proves the SUCCESS property (the views exist, carry
# the restored-plus-two column set, preserve their cardinality exactly, and
# carry the RIGHT ranks - checked against an oracle computed in R, not by
# re-running the view's own SQL).

.mig005_marker_version <- 1005L

# The 5 views this migration drops + recreates - identical to 004's list, and
# deliberately NOT `v_feature_dates` (F.11's, not this migration's).
.mig005_five_views <- c(
  "v_measurement", "v_measurement_epa",
  "v_measurement_gas_report", "v_measurement_long", "v_measurement_old"
)

.mig005_variant_literal <- c(
  v_measurement_epa = "EPA",
  v_measurement_old = "OLD",
  v_measurement_gas_report = "GAS_REPORT",
  v_measurement_long = "LONG"
)

.mig005_default <- function(x, default) if (is.null(x)) default else x

# 004's Sydney-calendar-date expression, reused VERBATIM. It appears twice in
# every view now - once projected as `date`, once inside `PARTITION BY` - and
# the two must be the same expression or the rank would be keyed on a day the
# view does not report. One constant is what makes that impossible.
.mig005_sydney_date_expr <- "CAST(s.datetime AT TIME ZONE 'UTC' AT TIME ZONE 'Australia/Sydney' AS DATE)"

#' The field-method list, read from `R/reconcile.R` rather than re-derived
#'
#' `.RC_FIELD_METHODS` is the single source of truth for "this lab_method
#' represents a FIELD measurement" - R-8.9's transcription supersession keys on
#' it, and so must the read-time ranking, or an ACIRL row could be protected
#' from supersession as a field reading while the views rank it as lab (or the
#' reverse). Deliberately NOT copied into this file: a copy can drift, and the
#' drift would be silent in both directions.
#'
#' @return character vector of `lab_method.method` values that rank as field.
.mig005_field_methods <- function() {
  if (!exists(".RC_FIELD_METHODS", mode = "character")) {
    cli::cli_abort(
      "005-preference-rank: `.RC_FIELD_METHODS` (R/reconcile.R) is not visible.
       This migration must be run from a session where the package was loaded
       with {.code devtools::load_all(\".\")} - see the file header.",
      class = "sampletidy_error"
    )
  }
  get(".RC_FIELD_METHODS")
}

#' SQL boolean: does this row's `lab_method` represent a field measurement?
#'
#' COALESCEd to FALSE - `lm.method IN (...)` yields NULL, not FALSE, for the
#' 3,170 analyses on a NULL-method lab_method, and a NULL ordering key relies
#' on DuckDB's NULLS-LAST default for its correctness (header note (c)).
#'
#' @param field_methods character vector from `.mig005_field_methods()`.
#' @return length-1 character SQL expression.
.mig005_is_field_sql <- function(field_methods) {
  sprintf(
    "COALESCE(lm.method IN (%s), FALSE)",
    paste(sprintf("'%s'", field_methods), collapse = ", ")
  )
}

# Among lab rows, ALS outranks ACIRL. COALESCEd for the same reason as
# `is_field` - `lm.organisation` is nullable, and on a LEFT-JOINed mask view it
# is NULL for any analysis whose lab_method is missing.
.mig005_is_als_sql <- "COALESCE(lm.organisation = 'ALS', FALSE)"

# The partition a row competes within: one sampling visit's reading of one
# analyte at one point.
#
# `COALESCE(lm.uuid_analyte, 'analysis:' || a.uuid)` rather than a bare
# `lm.uuid_analyte`: a row whose analyte cannot be determined must compete with
# NOTHING (a partition of one, always rank 1). A bare NULL would instead group
# EVERY unresolvable row for that feature and day into one partition and mark
# all but one of them non-canonical - silently hiding rows that were never
# duplicates. This cannot fire on the live DB today (zero analyses have a NULL
# or dangling `uuid_analyte`, measured) and is written to stay correct if that
# ever changes, which is exactly when nobody will be looking.
.mig005_partition_sql <- sprintf(
  "f.uuid, %s, COALESCE(lm.uuid_analyte, 'analysis:' || a.uuid)",
  .mig005_sydney_date_expr
)

#' The `preference_rank` window expression
#'
#' `s.uuid` is the THIRD ordering key and `a.uuid` the fourth, and the sample
#' key was added after the ranking was first measured on the live database
#' (`scratchpad/m6a_frankenstein.R`). Without it the final tiebreak is the
#' ANALYSIS uuid, which bears no relation to the sample the analysis came
#' from - so on a feature/date where two distinct samples were both analysed,
#' `preference_rank = 1` could select a DIFFERENT sample for each analyte.
#' Measured: **62** feature/date groups did exactly that, and the clearest is
#' the dust triple at B.D07 on 2021-08-01, where combustible came from one
#' gauge and incombustible and total from the other - so the rank-1 rows read
#' 0.6 + 2.2 against a total of 4.2, while within either sample the triple
#' sums correctly. A consumer filtering `WHERE preference_rank = 1` was getting
#' a row set assembled from more than one physical sample. Ordering on the
#' sample first makes every analyte in a feature/date agree on which sample
#' wins. It changes nothing for field-vs-lab, where `is_field DESC` already
#' dominates: it can only break ties the first two keys leave open.
#'
#' `a.uuid` remains the last key and is still load-bearing, not decorative:
#' 74 live partitions hold two field rows, which the first two keys cannot
#' separate, and an unstable `preference_rank` would be worse than the
#' ambiguity this migration removes (header note (b)).
#'
#' @param field_methods character vector from `.mig005_field_methods()`.
#' @return length-1 character SQL expression.
.mig005_rank_sql <- function(field_methods) {
  sprintf(
    "ROW_NUMBER() OVER (PARTITION BY %s ORDER BY %s DESC, %s DESC, s.uuid, a.uuid)",
    .mig005_partition_sql, .mig005_is_field_sql(field_methods), .mig005_is_als_sql
  )
}

.mig005_ensure_icu <- function(con) {
  DBI::dbExecute(con, "INSTALL icu")
  DBI::dbExecute(con, "LOAD icu")
  invisible(NULL)
}

# ---- mig005_counts_checksum() -----------------------------------------------

#' Row counts + a value checksum over the base tables this migration never
#' writes to (004's shape, reused rather than referenced - each migration file
#' is `sys.source()`d standalone)
#'
#' @param con an open DBI connection.
#' @return named list(feature, feature_alias, feature_mask, sample, analysis,
#'   lab_method, checksum).
mig005_counts_checksum <- function(con) {
  feature_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature")$n
  alias_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_alias")$n
  mask_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_mask")$n
  sample_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM \"sample\"")$n
  analysis_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n
  lab_method_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n

  feature_vals <- DBI::dbGetQuery(con, "SELECT uuid, name, site, flow FROM feature ORDER BY uuid")
  alias_vals <- DBI::dbGetQuery(
    con, "SELECT uuid, uuid_feature, alias_key FROM feature_alias ORDER BY uuid"
  )
  mask_vals <- DBI::dbGetQuery(
    con, "SELECT uuid_feature, variant, name FROM feature_mask ORDER BY uuid_feature, variant, name"
  )
  sample_vals <- DBI::dbGetQuery(
    con, "SELECT uuid, uuid_feature_alias, \"date\", datetime FROM \"sample\" ORDER BY uuid"
  )
  analysis_vals <- DBI::dbGetQuery(
    con, "SELECT uuid, uuid_sample, uuid_lab, value FROM analysis ORDER BY uuid"
  )
  # `method` and `organisation` are included here (004 selected only
  # uuid/uuid_analyte/name) because THIS migration's output depends on them -
  # the checksum should cover every column the ranking reads, so "the ranking
  # changed because the registry changed underneath it" cannot be mistaken for
  # "the migration touched a base table".
  lab_method_vals <- DBI::dbGetQuery(
    con,
    "SELECT uuid, uuid_analyte, name, method, organisation FROM lab_method ORDER BY uuid"
  )

  checksum <- digest::digest(
    list(feature_vals, alias_vals, mask_vals, sample_vals, analysis_vals, lab_method_vals),
    algo = "sha1"
  )

  list(
    feature = as.integer(feature_n),
    feature_alias = as.integer(alias_n),
    feature_mask = as.integer(mask_n),
    sample = as.integer(sample_n),
    analysis = as.integer(analysis_n),
    lab_method = as.integer(lab_method_n),
    checksum = checksum
  )
}

# ---- mig005_verify() ---------------------------------------------------------

#' Step hard verify gate - every base table byte-identical before/after
#'
#' @param before,after `mig005_counts_checksum()`-shaped lists.
#' @return invisible(TRUE) if every field matches; throws otherwise.
mig005_verify <- function(before, after) {
  fields <- c(
    "feature", "feature_alias", "feature_mask", "sample", "analysis",
    "lab_method", "checksum"
  )
  bad <- Filter(function(f) !identical(before[[f]], after[[f]]), fields)
  if (length(bad) > 0) {
    cli::cli_abort(
      "005-preference-rank verify failed: mismatch in {paste(bad, collapse = ', ')}.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

# ---- mig005_backup() ---------------------------------------------------------

.mig005_backup_counts <- function(con) {
  list(
    feature = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature")$n,
    sample = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM \"sample\"")$n,
    analysis = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n,
    lab_method = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n
  )
}

#' Back up and VERIFY the live DB before any write (mirrors `mig004_backup()`)
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory to write the backup into.
#' @param .now inject a POSIXct instead of `Sys.time()`.
#' @return absolute path to the verified backup copy.
mig005_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig005_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  fname <- sprintf("monitoring_pre-005-preference-rank_%sZ.duckdb", ts)
  dest <- file.path(snapshot_dir, fname)

  live_counts <- with_db_write(
    function(con) {
      DBI::dbExecute(con, "CHECKPOINT")
      counts <- .mig005_backup_counts(con)
      ok <- tryCatch(
        suppressWarnings(file.copy(db, dest, overwrite = FALSE)),
        error = function(e) FALSE
      )
      if (!isTRUE(ok)) {
        cli::cli_abort(
          "{db}: failed to write backup copy to {dest}.",
          class = "sampletidy_error"
        )
      }
      counts
    },
    db = db
  )

  verify_con <- tryCatch(
    DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE),
    error = function(e) NULL
  )
  if (is.null(verify_con)) {
    cli::cli_abort(
      "{db}: backup verification failed - cannot open {dest} read-only.",
      class = "sampletidy_error"
    )
  }
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)

  backup_counts <- .mig005_backup_counts(verify_con)
  if (!identical(live_counts, backup_counts)) {
    cli::cli_abort(
      "{db}: backup verification failed - row counts differ between live DB and {dest}.",
      class = "sampletidy_error"
    )
  }

  dest
}

# ---- view DDL -----------------------------------------------------------

#' Drop the 5 views and recreate them with `is_field` + `preference_rank`
#'
#' Every column 004 restored is carried through UNCHANGED - this migration is
#' strictly additive on the projection, and a dropped column here would
#' silently undo 004's own repair.
#'
#' `v_measurement` keeps 004's INNER joins exactly. The 4 mask views gain
#' `LEFT JOIN lab_method` - LEFT, not INNER, deliberately: the ranking needs
#' `method`/`organisation`/`uuid_analyte`, but an INNER JOIN would DROP any
#' analysis whose `uuid_lab` is dangling and so change the row count that
#' R-15.35 pins. There are none on the live DB today (measured), which means an
#' INNER JOIN would pass the gate now and become a silent data-loss bug later;
#' LEFT makes cardinality preservation structural instead of lucky. Such a row
#' ranks as `is_field = FALSE`, `is_als = FALSE`, in a partition of one.
#'
#' The `feature_mask` join stays INNER - it is the filter, not a lookup.
#'
#' @param con an open read-write DBI connection, inside the caller's
#'   transaction.
#' @return invisible(NULL).
.mig005_rebuild_views <- function(con) {
  field_methods <- .mig005_field_methods()
  is_field <- .mig005_is_field_sql(field_methods)
  rank_sql <- .mig005_rank_sql(field_methods)

  for (v in .mig005_five_views) {
    DBI::dbExecute(con, sprintf("DROP VIEW IF EXISTS %s", v))
  }

  DBI::dbExecute(con, sprintf("
    CREATE VIEW v_measurement AS
      SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature,
             f.name AS feature_name, a.value,
             %s AS date,
             s.datetime AS datetime,
             an.name AS analyte_name,
             an.units AS analyte_units,
             f.site AS site,
             f.flow AS feature_flow,
             f.lon AS lon,
             f.lat AS lat,
             a.rl_low AS rl_low,
             a.rl_high AS rl_high,
             %s AS is_field,
             %s AS preference_rank
      FROM analysis a
      JOIN \"sample\" s ON a.uuid_sample = s.uuid
      JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
      JOIN feature f ON fa.uuid_feature = f.uuid
      JOIN lab_method lm ON a.uuid_lab = lm.uuid
      JOIN analyte an ON lm.uuid_analyte = an.uuid
  ", .mig005_sydney_date_expr, is_field, rank_sql))

  for (view_name in names(.mig005_variant_literal)) {
    literal <- .mig005_variant_literal[[view_name]]
    DBI::dbExecute(con, sprintf("
      CREATE VIEW %s AS
        SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature,
               f.name AS feature_name, a.value,
               %s AS date,
               s.datetime AS datetime,
               f.site AS site,
               f.flow AS feature_flow,
               f.lon AS lon,
               f.lat AS lat,
               fm.name AS mask_name,
               %s AS is_field,
               %s AS preference_rank
        FROM analysis a
        JOIN \"sample\" s ON a.uuid_sample = s.uuid
        JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
        JOIN feature f ON fa.uuid_feature = f.uuid
        LEFT JOIN lab_method lm ON a.uuid_lab = lm.uuid
        JOIN feature_mask fm ON fm.uuid_feature = f.uuid AND UPPER(fm.variant) = '%s'
    ", view_name, .mig005_sydney_date_expr, is_field, rank_sql, literal))
  }

  invisible(NULL)
}

# ---- .mig005_verify_views() ----------------------------------------------

# 004's restored column set, PLUS this migration's two. Written as 004's list
# plus an explicit addition rather than as a fresh literal, so a future reader
# can see at a glance that nothing 004 restored was dropped.
.mig005_added_cols <- c("is_field", "preference_rank")

.mig005_expected_view_cols <- local({
  base <- list(
    v_measurement = c(
      "uuid_analysis", "uuid_sample", "uuid_feature", "feature_name", "value",
      "date", "datetime", "analyte_name", "analyte_units", "site",
      "feature_flow", "lon", "lat", "rl_low", "rl_high"
    ),
    v_measurement_epa = c(
      "uuid_analysis", "uuid_sample", "uuid_feature", "feature_name", "value",
      "date", "datetime", "site", "feature_flow", "lon", "lat", "mask_name"
    )
  )
  base$v_measurement_gas_report <- base$v_measurement_epa
  base$v_measurement_long <- base$v_measurement_epa
  base$v_measurement_old <- base$v_measurement_epa
  lapply(base, function(cols) c(cols, .mig005_added_cols))
})

#' Independently-computed base-table row count for one of the 5 views (004's
#' `.mig004_base_n()`, unchanged in intent)
#'
#' NOT a copy of the view's own SQL: reads each base table with a plain
#' unjoined SELECT and intersects uuid sets in R, sharing neither the view's
#' JOIN topology nor its literal case-form. Carried into 005 because this
#' migration's central safety claim is that adding a window function and a
#' LEFT JOIN changed NO view's cardinality - which is exactly what this
#' function is able to falsify.
#'
#' CORRECTED relative to `.mig004_base_n()`, which applied `uuid_lab %in%
#' lab_method` to ALL FIVE views. That was wrong for the four mask views even
#' before this migration: they never joined `lab_method` at all, so an analysis
#' with a NULL or dangling `uuid_lab` appeared in them while the oracle refused
#' to count it. It has never fired (zero such rows on the live DB, measured),
#' which is precisely why it survived - a gate that is only correct because its
#' failing case is empty. The mask views' `LEFT JOIN lab_method` keeps that
#' behaviour exactly, so the oracle is fixed to match rather than the view bent
#' to match the oracle: requiring a resolvable `lab_method` (and, through it, a
#' resolvable `analyte`) is `v_measurement`'s INNER-join semantics ONLY.
#'
#' @param con an open DBI connection.
#' @param variant_literal the UPPERCASE mask variant, or `NULL` for
#'   `v_measurement`.
#' @return integer(1).
.mig005_base_n <- function(con, variant_literal = NULL) {
  analysis_tbl <- DBI::dbGetQuery(con, "SELECT uuid, uuid_sample, uuid_lab FROM analysis")
  sample_tbl <- DBI::dbGetQuery(con, "SELECT uuid, uuid_feature_alias FROM \"sample\"")
  alias_tbl <- DBI::dbGetQuery(con, "SELECT uuid, uuid_feature FROM feature_alias")
  lab_method_tbl <- DBI::dbGetQuery(con, "SELECT uuid, uuid_analyte FROM lab_method")
  analyte_tbl <- DBI::dbGetQuery(con, "SELECT uuid FROM analyte")

  alias_resolved <- alias_tbl$uuid[!is.na(alias_tbl$uuid_feature)]
  sample_ok <- sample_tbl$uuid[sample_tbl$uuid_feature_alias %in% alias_resolved]
  keep <- analysis_tbl$uuid_sample %in% sample_ok

  if (is.null(variant_literal)) {
    # v_measurement alone INNER JOINs lab_method and then analyte, so a row
    # missing either is genuinely absent from it.
    lab_ok <- lab_method_tbl$uuid[lab_method_tbl$uuid_analyte %in% analyte_tbl$uuid]
    keep <- keep & (analysis_tbl$uuid_lab %in% lab_ok)
  }

  if (!is.null(variant_literal)) {
    mask_tbl <- DBI::dbGetQuery(con, "SELECT uuid_feature, variant FROM feature_mask")
    masked_features <- unique(mask_tbl$uuid_feature[toupper(mask_tbl$variant) == variant_literal])
    masked_aliases <- alias_tbl$uuid[alias_tbl$uuid_feature %in% masked_features]
    sample_masked <- sample_tbl$uuid[sample_tbl$uuid_feature_alias %in% masked_aliases]
    keep <- keep & (analysis_tbl$uuid_sample %in% sample_masked)
  }

  as.integer(sum(keep))
}

#' The `preference_rank` ORACLE - every row's expected rank, computed in R
#'
#' The whole point of this migration is the rank column, and a count-based gate
#' cannot see it: a view that ranks every row 1 has exactly the same
#' cardinality as a correct one. This recomputes the rank for every row from
#' flat base-table reads, by a mechanism that shares nothing with the view:
#'
#'  * the Sydney calendar date comes from R's own `as.Date(..., tz =)` over a
#'    UTC timestamp string, NOT from DuckDB's ICU `AT TIME ZONE` - so a broken
#'    or unloaded `icu` extension shows up as a mismatch rather than as two
#'    identically-wrong answers;
#'  * the ordering is R's `order(method = "radix")` (C-locale byte order for
#'    the uuid tiebreak, which is what DuckDB's VARCHAR comparison does), not a
#'    second `ROW_NUMBER()`;
#'  * `is_field` / `is_als` are computed with `%in%` and `identical`-style
#'    NA-safe R logic rather than by re-issuing the same COALESCE SQL.
#'
#' @param con an open DBI connection.
#' @param field_methods character vector from `.mig005_field_methods()`.
#' @return data.frame(uuid_analysis, expected_rank, expected_is_field), one row
#'   per analysis reachable by `v_measurement` (INNER-join semantics).
.mig005_rank_oracle <- function(con, field_methods) {
  # `strftime` renders the stored naive timestamp as text; R then attaches UTC
  # and converts. Deliberately not letting the driver hand back a POSIXct whose
  # tzone attribute is environment-dependent - that would make this oracle
  # sensitive to the R session's TZ, which is the one thing the 004 ruling says
  # the answer must never depend on.
  rows <- DBI::dbGetQuery(con, "
    SELECT a.uuid AS uuid_analysis,
           s.uuid AS uuid_sample,
           fa.uuid_feature AS uuid_feature,
           strftime(s.datetime, '%Y-%m-%d %H:%M:%S') AS dt_utc,
           lm.uuid_analyte AS uuid_analyte,
           lm.method AS method,
           lm.organisation AS organisation
    FROM analysis a
    JOIN \"sample\" s ON a.uuid_sample = s.uuid
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON fa.uuid_feature = f.uuid
    JOIN lab_method lm ON a.uuid_lab = lm.uuid
    JOIN analyte an ON lm.uuid_analyte = an.uuid")

  if (nrow(rows) == 0) {
    return(data.frame(
      uuid_analysis = character(0), expected_rank = integer(0),
      expected_is_field = logical(0), stringsAsFactors = FALSE
    ))
  }

  dt <- as.POSIXct(rows$dt_utc, tz = "UTC", format = "%Y-%m-%d %H:%M:%S")
  syd_date <- format(dt, tz = "Australia/Sydney", format = "%Y-%m-%d")

  is_field <- !is.na(rows$method) & rows$method %in% field_methods
  is_als <- !is.na(rows$organisation) & rows$organisation == "ALS"

  analyte_key <- ifelse(
    is.na(rows$uuid_analyte), paste0("analysis:", rows$uuid_analysis), rows$uuid_analyte
  )
  # "\r" as the separator: it cannot occur in a uuid, a date or an analyte
  # uuid, so two different key triples can never collide into one string.
  key <- paste(rows$uuid_feature, syd_date, analyte_key, sep = "\r")

  # Same key order as the view, reached independently: R's own radix order is
  # C-locale byte order for character, which is what DuckDB's VARCHAR
  # comparison does. `uuid_sample` before `uuid_analysis` mirrors `s.uuid,
  # a.uuid` - see the note on `.mig005_rank_sql()`.
  o <- order(key, !is_field, !is_als, rows$uuid_sample, rows$uuid_analysis,
             method = "radix")
  ranks <- integer(length(key))
  ranks[o] <- sequence(rle(key[o])$lengths)

  data.frame(
    uuid_analysis = rows$uuid_analysis,
    expected_rank = ranks,
    expected_is_field = is_field,
    stringsAsFactors = FALSE
  )
}

#' The SUCCESS-property verify gate
#'
#' `mig005_verify()` alone is blind to this migration's reason for being (004's
#' own lesson, item 1): it compares only the 6 base tables 005 never writes, so
#' a run where `.mig005_rebuild_views()` did nothing still passes it. Four
#' checks, each able to falsify a different way this can go wrong:
#'
#'  A. the 5 views exist and carry 004's columns PLUS `is_field` +
#'     `preference_rank` (catches a dropped projection - a silent undo of 004);
#'  B. every view's row count equals `.mig005_base_n()` (catches the window
#'     function or the new LEFT JOIN changing cardinality, and re-checks 004's
#'     case-insensitive mask filter has not regressed);
#'  C. `v_measurement`'s `preference_rank` and `is_field` match
#'     `.mig005_rank_oracle()` ROW FOR ROW (catches a wrong partition key, a
#'     wrong ordering, an NA-poisoned COALESCE, a nondeterministic tiebreak -
#'     none of which change any count);
#'  D. at least one partition in `v_measurement` actually holds more than one
#'     row. Adopted from 004's S2 for the same reason: on a DB with no
#'     contested partition every rank is trivially 1, and check C passes
#'     vacuously - indistinguishable from a rebuild that regressed to ranking
#'     everything 1. Refused rather than passed.
#'
#' Called inside the caller's transaction, before COMMIT, so a failure rolls
#' back the whole migration including the 1005 marker.
#'
#' @param con an open DBI connection, inside the caller's transaction.
#' @return invisible(TRUE) if every check holds; throws otherwise.
.mig005_verify_views <- function(con) {
  # ---- A. existence + column set ----
  bad_views <- character(0)
  for (v in .mig005_five_views) {
    expected_cols <- .mig005_expected_view_cols[[v]]
    if (is.null(expected_cols)) {
      cli::cli_abort(
        "005-preference-rank internal error: {.val {v}} is listed in
         .mig005_five_views but has no entry in .mig005_expected_view_cols -
         the two lists have drifted apart.",
        class = "sampletidy_error"
      )
    }
    cols <- tryCatch(DBI::dbListFields(con, v), error = function(e) NULL)
    if (is.null(cols) || !setequal(cols, expected_cols)) {
      bad_views <- c(bad_views, v)
    }
  }
  if (length(bad_views) > 0) {
    cli::cli_abort(
      "005-preference-rank verify failed: view(s) missing or carrying the wrong
       column set after rebuild: {paste(bad_views, collapse = ', ')}.",
      class = "sampletidy_error"
    )
  }

  # ---- B. cardinality unchanged ----
  bad_counts <- character(0)
  zero_base <- character(0)
  for (v in .mig005_five_views) {
    literal <- if (v %in% names(.mig005_variant_literal)) {
      .mig005_variant_literal[[v]]
    } else {
      NULL
    }
    view_n <- as.integer(DBI::dbGetQuery(con, sprintf("SELECT COUNT(*) n FROM %s", v))$n)
    base_n <- .mig005_base_n(con, literal)
    if (identical(base_n, 0L)) {
      zero_base <- c(zero_base, v)
    } else if (!identical(view_n, base_n)) {
      bad_counts <- c(bad_counts, sprintf("%s (view=%s, base=%s)", v, view_n, base_n))
    }
  }
  if (length(zero_base) > 0) {
    cli::cli_abort(
      "005-preference-rank verify failed: the independent base-table oracle
       returned ZERO for {paste(zero_base, collapse = ', ')} - a zero count
       cannot be distinguished from a rebuild that silently regressed to
       matching nothing, so it is refused rather than passed.",
      class = "sampletidy_error"
    )
  }
  if (length(bad_counts) > 0) {
    cli::cli_abort(
      "005-preference-rank verify failed: adding `preference_rank` changed a
       view's row count, which it must never do -
       {paste(bad_counts, collapse = '; ')}.",
      class = "sampletidy_error"
    )
  }

  # ---- C. the ranks themselves ----
  oracle <- .mig005_rank_oracle(con, .mig005_field_methods())
  got <- DBI::dbGetQuery(
    con, "SELECT uuid_analysis, is_field, preference_rank FROM v_measurement"
  )
  merged <- merge(oracle, got, by = "uuid_analysis", all = TRUE)
  bad_rank <- merged[
    is.na(merged$preference_rank) | is.na(merged$expected_rank) |
      merged$preference_rank != merged$expected_rank |
      merged$is_field != merged$expected_is_field, ,
    drop = FALSE
  ]
  if (nrow(bad_rank) > 0) {
    ex <- utils::head(bad_rank, 3)
    cli::cli_abort(
      "005-preference-rank verify failed: {nrow(bad_rank)} of {nrow(merged)}
       v_measurement rows carry a preference_rank/is_field that disagrees with
       the independently computed oracle (e.g.
       {paste(sprintf('%s: view rank %s / oracle %s', ex$uuid_analysis,
                      ex$preference_rank, ex$expected_rank), collapse = '; ')}).",
      class = "sampletidy_error"
    )
  }

  # ---- D. non-vacuity ----
  contested <- as.integer(DBI::dbGetQuery(
    con, "SELECT COUNT(*) n FROM v_measurement WHERE preference_rank > 1"
  )$n)
  if (identical(contested, 0L)) {
    cli::cli_abort(
      "005-preference-rank verify failed: NO partition in v_measurement holds
       more than one row, so every rank is trivially 1 and the rank oracle
       passed vacuously - indistinguishable from a rebuild that regressed to
       ranking everything 1. Refused rather than passed.",
      class = "sampletidy_error"
    )
  }

  invisible(TRUE)
}

# ---- mig005_run() -------------------------------------------------------

#' Run (or dry-run) the 005-preference-rank migration
#'
#' Never invoked by package code (A50). Depends on 004-view-repair.R having
#' already applied to `db`.
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory for the pre-migration backup.
#' @param dry_run if `TRUE`, print what would happen and write nothing.
#' @param .now inject a POSIXct instead of `Sys.time()`.
#' @return invisible list(status, backup_path, restore_command, counts_before,
#'   counts_after, recorded_at).
mig005_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  # Fail FAST and in the caller's session if the package was not loaded with
  # `devtools::load_all(".")` - before the backup is taken, so a stray copy is
  # not left behind by a run that could never have succeeded.
  field_methods <- .mig005_field_methods()

  # ---- Step 0: idempotency guard AND the 004-dependency precondition ----
  marker_con <- st_connect(db, read_only = TRUE)
  if (!("schema_version" %in% DBI::dbListTables(marker_con))) {
    DBI::dbDisconnect(marker_con, shutdown = TRUE)
    cli::cli_abort(
      "{db}: no schema_version table found - ensure_schema() has never been
       applied to this database, so 005-preference-rank cannot check its own
       idempotency marker.",
      class = "sampletidy_error"
    )
  }
  markers <- tryCatch(
    DBI::dbGetQuery(
      marker_con, "SELECT version, applied_at FROM schema_version WHERE version IN (?, ?)",
      params = list(.mig005_marker_version, 1004L)
    ),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE)
  )
  marker <- markers[markers$version == .mig005_marker_version, ]

  if (nrow(marker) > 0) {
    recorded_at <- marker$applied_at[[1]]
    logf("005-preference-rank already applied at %s; nothing to do.", format(recorded_at))
    read_con <- st_connect(db, read_only = TRUE)
    counts <- tryCatch(
      mig005_counts_checksum(read_con),
      finally = DBI::dbDisconnect(read_con, shutdown = TRUE)
    )
    return(invisible(list(
      status = "already_migrated",
      backup_path = NA_character_,
      restore_command = NA_character_,
      counts_before = counts,
      counts_after = counts,
      recorded_at = recorded_at
    )))
  }

  if (!(1004L %in% markers$version)) {
    cli::cli_abort(
      "{db}: 004-view-repair has not been applied to this database (no 1004
       schema_version marker) - 005-preference-rank rebuilds 004's OWN views
       and carries every column 004 restored, so running it first would
       re-gut the projection 004 exists to repair.",
      class = "sampletidy_error"
    )
  }

  # ---- dry-run: preview only, write nothing (no backup either). ----
  if (isTRUE(dry_run)) {
    preview_con <- st_connect(db, read_only = TRUE)
    counts_before <- tryCatch(
      mig005_counts_checksum(preview_con),
      finally = DBI::dbDisconnect(preview_con, shutdown = TRUE)
    )
    logf("DRY RUN: would drop + recreate %d views: %s.",
      length(.mig005_five_views), paste(.mig005_five_views, collapse = ", "))
    logf("DRY RUN: adding is_field + preference_rank; field methods are %s.",
      paste(sprintf("'%s'", field_methods), collapse = ", "))
    logf("DRY RUN: no backup taken, no writes made to %s.", db)
    return(invisible(list(
      status = "dry_run",
      backup_path = NA_character_,
      restore_command = NA_character_,
      counts_before = counts_before,
      counts_after = NA,
      recorded_at = NA
    )))
  }

  # ---- Step 1: back up and verify, before any write. ----
  backup_path <- mig005_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)

  recorded_at <- .mig005_default(.now, Sys.time())

  result <- with_db_write(
    function(con) {
      .mig005_ensure_icu(con)
      counts_before <- mig005_counts_checksum(con)

      body <- db_transaction(con, function(con) {
        .mig005_rebuild_views(con)

        DBI::dbExecute(
          con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
          params = list(.mig005_marker_version, recorded_at)
        )

        counts_after <- mig005_counts_checksum(con)
        mig005_verify(counts_before, counts_after)
        .mig005_verify_views(con)

        list(counts_after = counts_after)
      })

      logf("Verify passed: base tables unchanged; views rebuilt with preference_rank.")

      list(counts_before = counts_before, counts_after = body$counts_after)
    },
    db = db
  )

  logf("005-preference-rank migrated successfully.")

  invisible(list(
    status = "migrated",
    backup_path = backup_path,
    restore_command = restore_command,
    counts_before = result$counts_before,
    counts_after = result$counts_after,
    recorded_at = recorded_at
  ))
}
