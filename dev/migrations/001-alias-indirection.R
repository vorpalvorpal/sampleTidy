# PLAN-13 (B-13.1, B-13.2) - operator-run migration: retire feature.cypher's
# direct sample.uuid_feature link in favour of an indirection table
# (`feature_alias`), and restore `lab_method.units` /
# `lab_method.conversion_constant` (A63).
#
# NEVER invoked by package code (A50) - no `ensure_schema()`, `ingest_dir()`
# or other package entry point sources this file. An operator runs it
# directly, e.g.:
#   env <- new.env()
#   sys.source("dev/migrations/001-alias-indirection.R", envir = env)
#   env$mig001_run(db = "/path/to/monitoring.duckdb",
#                   snapshot_dir = "/path/to/snapshots", dry_run = TRUE)
#
# Reuses `with_db_write()` / `st_connect()` (R/db-connect.R) rather than
# re-deriving connection/locking logic (A50's "reuse, don't re-derive").
#
# ---- schema_version marker representation (surfaced per Phase-6 brief) ----
# PLAN-01 R-1.5 pins `schema_version(version INTEGER, applied_at TIMESTAMP)`
# EXACTLY - this migration must not alter that shape. PLAN-13 step 0 talks
# of "the schema_version marker for '001-alias-indirection'" in prose, but
# the table itself has no string-key column to hold that literal. Resolution
# chosen here: reserve an INTEGER version number, 1001L, for this
# operator-run migration - well outside the 1-4 range `.st_schema_migrations`
# (R/db-schema.R) uses for the ops-table migrations it tracks in the SAME
# table, so the two numbering spaces cannot collide. `applied_at` still
# records a real TIMESTAMP. This keeps the pinned exact shape untouched and
# needs no new table; the "which representation" question is squarely a
# storage-shape choice PLAN-13 leaves open, not a leaked business meaning,
# so pinning it to an INTEGER (matching the table's actual column type)
# rather than inventing a string column is the conservative reading. Flagged
# for the orchestrator to formally pin.

.mig001_marker_version <- 1001L

.mig001_six_views <- c(
  "v_feature_dates", "v_measurement", "v_measurement_epa",
  "v_measurement_gas_report", "v_measurement_long", "v_measurement_old"
)

.mig001_default <- function(x, default) if (is.null(x)) default else x

.mig001_normalize <- function(x) tolower(trimws(x))

# ---- mig001_counts_checksum() ----------------------------------------------

#' Row counts + a value checksum over columns stable across the migration
#'
#' Deliberately selects only columns that exist, and hold the same values,
#' both BEFORE and AFTER the migration (feature is untouched; sample's
#' `date`; analysis's `uuid_sample`/`uuid_lab`/`value`; lab_method's
#' `uuid_analyte`/`name` - never `uuid_feature` on sample, dropped by the
#' migration, nor `units`/`conversion_constant`, added by it).
#'
#' @param con an open DBI connection.
#' @return named list(feature, sample, analysis, lab_method, checksum).
mig001_counts_checksum <- function(con) {
  feature_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature")$n
  sample_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM \"sample\"")$n
  analysis_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n
  lab_method_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n

  feature_vals <- DBI::dbGetQuery(con, "SELECT uuid, name, cypher FROM feature ORDER BY uuid")
  sample_vals <- DBI::dbGetQuery(con, "SELECT uuid, \"date\" FROM \"sample\" ORDER BY uuid")
  analysis_vals <- DBI::dbGetQuery(
    con, "SELECT uuid, uuid_sample, uuid_lab, value FROM analysis ORDER BY uuid"
  )
  lab_method_vals <- DBI::dbGetQuery(
    con, "SELECT uuid, uuid_analyte, name FROM lab_method ORDER BY uuid"
  )

  checksum <- digest::digest(
    list(feature_vals, sample_vals, analysis_vals, lab_method_vals),
    algo = "sha1"
  )

  list(
    feature = as.integer(feature_n),
    sample = as.integer(sample_n),
    analysis = as.integer(analysis_n),
    lab_method = as.integer(lab_method_n),
    checksum = checksum
  )
}

# ---- mig001_verify() --------------------------------------------------------

#' Step-11 hard verify gate
#'
#' @param before,after `mig001_counts_checksum()`-shaped lists.
#' @return invisible(TRUE) if every field matches; throws otherwise.
mig001_verify <- function(before, after) {
  fields <- c("feature", "sample", "analysis", "lab_method", "checksum")
  bad <- Filter(function(f) !identical(before[[f]], after[[f]]), fields)
  if (length(bad) > 0) {
    cli::cli_abort(
      "001-alias-indirection verify failed: mismatch in {paste(bad, collapse = ', ')}.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

# ---- mig001_backup() --------------------------------------------------------

.mig001_backup_counts <- function(con) {
  list(
    feature = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature")$n,
    sample = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM \"sample\"")$n,
    analysis = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n,
    lab_method = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n
  )
}

#' Step 1 - back up and VERIFY the live DB before any write
#'
#' Timestamped (millisecond precision), never the `snapshot_db()` date-only
#' naming scheme (that is date-keyed and a same-day re-snapshot overwrites -
#' fatal for a pre-migration backup). CHECKPOINTs while holding the
#' `with_db_write()` lock so the copy is consistent, then verifies the copy
#' by opening it read-only and comparing row counts to the live DB. Throws,
#' writing nothing to `db`, on any failure.
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory to write the backup into.
#' @param .now inject a POSIXct instead of `Sys.time()` (deterministic
#'   same-day-collision testing).
#' @return absolute path to the verified backup copy.
mig001_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig001_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  fname <- sprintf("monitoring_pre-001-alias-indirection_%sZ.duckdb", ts)
  dest <- file.path(snapshot_dir, fname)

  live_counts <- with_db_write(
    function(con) {
      DBI::dbExecute(con, "CHECKPOINT")
      counts <- .mig001_backup_counts(con)
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

  backup_counts <- .mig001_backup_counts(verify_con)
  if (!identical(live_counts, backup_counts)) {
    cli::cli_abort(
      "{db}: backup verification failed - row counts differ between live DB and {dest}.",
      class = "sampletidy_error"
    )
  }

  dest
}

# ---- steps 3-5: feature_alias construction (also used for dry-run preview) -

#' Compute the full `feature_alias` row set (steps 3-5) without writing
#'
#' Self-aliases (step 3) seed at `n_seen = 0`; a cypher or mask-long entry
#' whose normalised key already matches an existing row for the SAME feature
#' folds into it (increments `n_seen`, kind/auto_assign untouched) rather
#' than creating a second row. New entries are classified
#' `historical_code` (no whitespace + >=1 digit) or `descriptive` (else) for
#' cypher, `mask_long` for feature_mask 'long' rows. After all imports, any
#' `alias_key` reaching more than one distinct `uuid_feature` is marked
#' `auto_assign = FALSE` on every row sharing that key.
#'
#' @param con an open DBI connection.
#' @return data.frame(alias_key, uuid_feature, kind, auto_assign, n_seen).
.mig001_compute_alias_rows <- function(con) {
  features <- DBI::dbGetQuery(con, "SELECT uuid, name, cypher FROM feature")
  masks <- DBI::dbGetQuery(
    con, "SELECT uuid_feature, name FROM feature_mask WHERE variant = 'long'"
  )

  rows <- list()
  order_keys <- character(0)

  add_or_increment <- function(alias_key, uuid_feature, kind) {
    k <- paste(alias_key, uuid_feature, sep = "")
    if (!is.null(rows[[k]])) {
      rows[[k]]$n_seen <<- rows[[k]]$n_seen + 1L
    } else {
      rows[[k]] <<- list(
        alias_key = alias_key, uuid_feature = uuid_feature,
        kind = kind, n_seen = 1L
      )
      order_keys <<- c(order_keys, k)
    }
  }

  # Step 3: self-aliases.
  for (i in seq_len(nrow(features))) {
    alias_key <- .mig001_normalize(features$name[i])
    k <- paste(alias_key, features$uuid[i], sep = "")
    rows[[k]] <- list(
      alias_key = alias_key, uuid_feature = features$uuid[i],
      kind = "self", n_seen = 0L
    )
    order_keys <- c(order_keys, k)
  }

  # Step 4: cypher import.
  for (i in seq_len(nrow(features))) {
    cypher <- features$cypher[i]
    if (is.na(cypher) || !nzchar(trimws(cypher))) next
    tokens <- trimws(strsplit(cypher, ",", fixed = TRUE)[[1]])
    tokens <- tokens[nzchar(tokens)]
    for (tok in tokens) {
      alias_key <- .mig001_normalize(tok)
      has_ws <- grepl("\\s", alias_key)
      has_digit <- grepl("[0-9]", alias_key)
      kind <- if (!has_ws && has_digit) "historical_code" else "descriptive"
      add_or_increment(alias_key, features$uuid[i], kind)
    }
  }

  # Step 5: feature_mask 'long' import.
  for (i in seq_len(nrow(masks))) {
    alias_key <- .mig001_normalize(masks$name[i])
    add_or_increment(alias_key, masks$uuid_feature[i], "mask_long")
  }

  df_list <- lapply(order_keys, function(k) rows[[k]])
  alias_key <- vapply(df_list, function(r) r$alias_key, character(1))
  uuid_feature <- vapply(df_list, function(r) r$uuid_feature, character(1))
  kind <- vapply(df_list, function(r) r$kind, character(1))
  n_seen <- vapply(df_list, function(r) as.integer(r$n_seen), integer(1))
  auto_assign <- rep(TRUE, length(df_list))

  if (length(alias_key) > 0) {
    n_distinct_feature <- tapply(uuid_feature, alias_key, function(x) length(unique(x)))
    ambiguous_keys <- names(n_distinct_feature)[n_distinct_feature > 1]
    auto_assign[alias_key %in% ambiguous_keys] <- FALSE
  }

  data.frame(
    alias_key = alias_key, uuid_feature = uuid_feature, kind = kind,
    auto_assign = auto_assign, n_seen = n_seen,
    stringsAsFactors = FALSE
  )
}

# ---- mig001_run() -----------------------------------------------------------

#' Run (or dry-run) the 001-alias-indirection migration
#'
#' Steps 0-11 (PLAN-13 B-13.1) plus R-13.2's `lab_method` column-add, inside
#' one transaction (steps 3-10). Never invoked by package code (A50).
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory for the pre-migration backup.
#' @param dry_run if `TRUE`, print what would happen and write nothing.
#' @param .now inject a POSIXct instead of `Sys.time()` (propagated to the
#'   backup filename and the schema_version marker).
#' @return invisible list(status, backup_path, restore_command,
#'   counts_before, counts_after, ambiguous_count, recorded_at).
mig001_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  # ---- Step 0: idempotency guard - read-only, writes nothing. ----
  marker_con <- st_connect(db, read_only = TRUE)
  marker <- tryCatch(
    DBI::dbGetQuery(
      marker_con, "SELECT applied_at FROM schema_version WHERE version = ?",
      params = list(.mig001_marker_version)
    ),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE)
  )

  if (nrow(marker) > 0) {
    recorded_at <- marker$applied_at[[1]]
    logf("001-alias-indirection already applied at %s; nothing to do.", format(recorded_at))
    read_con <- st_connect(db, read_only = TRUE)
    counts <- tryCatch(
      mig001_counts_checksum(read_con),
      finally = DBI::dbDisconnect(read_con, shutdown = TRUE)
    )
    counts2_con <- st_connect(db, read_only = TRUE)
    counts2 <- tryCatch(
      mig001_counts_checksum(counts2_con),
      finally = DBI::dbDisconnect(counts2_con, shutdown = TRUE)
    )
    return(invisible(list(
      status = "already_migrated",
      backup_path = NA_character_,
      restore_command = NA_character_,
      counts_before = counts,
      counts_after = counts2,
      ambiguous_count = NA_integer_,
      recorded_at = recorded_at
    )))
  }

  # ---- dry-run: preview only, write nothing (no backup either). ----
  if (isTRUE(dry_run)) {
    preview_con <- st_connect(db, read_only = TRUE)
    preview <- tryCatch(
      {
        alias_rows <- .mig001_compute_alias_rows(preview_con)
        counts_before <- mig001_counts_checksum(preview_con)
        list(alias_rows = alias_rows, counts_before = counts_before)
      },
      finally = DBI::dbDisconnect(preview_con, shutdown = TRUE)
    )
    n_self <- sum(preview$alias_rows$kind == "self")
    ambiguous_count <- sum(!preview$alias_rows$auto_assign)
    logf("DRY RUN: would insert %d self-aliases, %d alias rows total.",
      n_self, nrow(preview$alias_rows))
    logf("DRY RUN: %d ambiguous alias rows would be flagged auto_assign = FALSE.",
      ambiguous_count)
    logf("DRY RUN: no backup taken, no writes made to %s.", db)
    return(invisible(list(
      status = "dry_run",
      backup_path = NA_character_,
      restore_command = NA_character_,
      counts_before = preview$counts_before,
      counts_after = NA,
      ambiguous_count = ambiguous_count,
      recorded_at = NA
    )))
  }

  # ---- Step 1: back up and verify, before any write. ----
  backup_path <- mig001_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)

  recorded_at <- .mig001_default(.now, Sys.time())

  result <- with_db_write(
    function(con) {
      counts_before <- mig001_counts_checksum(con)
      logf(
        "Pre-migration counts: feature=%d sample=%d analysis=%d lab_method=%d",
        counts_before$feature, counts_before$sample,
        counts_before$analysis, counts_before$lab_method
      )

      DBI::dbExecute(con, "BEGIN TRANSACTION")

      body <- tryCatch(
        {
          # ---- Step 3: feature_alias + self-aliases; steps 4-5 folded in. ----
          DBI::dbExecute(con, "
            CREATE TABLE feature_alias (
              uuid VARCHAR PRIMARY KEY,
              alias_key VARCHAR,
              uuid_feature VARCHAR,
              kind VARCHAR,
              auto_assign BOOLEAN,
              n_seen INTEGER
            )")

          alias_df <- .mig001_compute_alias_rows(con)
          if (nrow(alias_df) > 0) {
            alias_df$uuid <- uuid::UUIDgenerate(n = nrow(alias_df))
            alias_df <- alias_df[, c("uuid", "alias_key", "uuid_feature", "kind", "auto_assign", "n_seen")]
            DBI::dbWriteTable(con, "feature_alias", alias_df, append = TRUE)
          }
          ambiguous_count <- sum(!alias_df$auto_assign)
          logf("%d ambiguous alias rows flagged auto_assign = FALSE.", ambiguous_count)

          # ---- Step 6: drop the 6 views referencing sample.uuid_feature. ----
          for (v in .mig001_six_views) {
            DBI::dbExecute(con, sprintf("DROP VIEW %s", v))
          }

          # ---- Step 7: dump analysis, drop it (frees sample/lab_method FKs). ----
          DBI::dbExecute(con, "CREATE TEMP TABLE _mig001_analysis_backup AS SELECT * FROM analysis")
          DBI::dbExecute(con, "DROP TABLE analysis")

          # ---- Step 8: rebuild sample (uuid_feature -> uuid_feature_alias). ----
          DBI::dbExecute(con, "
            CREATE TABLE sample_new (
              uuid VARCHAR PRIMARY KEY,
              uuid_feature_alias VARCHAR REFERENCES feature_alias(uuid),
              uuid_project VARCHAR,
              date TIMESTAMP,
              date_start TIMESTAMP,
              datetime TIMESTAMP,
              datetime_start TIMESTAMP,
              organisation VARCHAR,
              person VARCHAR,
              purpose VARCHAR,
              comments VARCHAR
            )")
          DBI::dbExecute(con, "
            INSERT INTO sample_new
            SELECT s.uuid, fa.uuid, s.uuid_project, s.date, s.date_start, s.datetime,
                   s.datetime_start, s.organisation, s.person, s.purpose, s.comments
            FROM \"sample\" s
            JOIN feature_alias fa ON fa.uuid_feature = s.uuid_feature AND fa.kind = 'self'
          ")
          DBI::dbExecute(con, "DROP TABLE \"sample\"")
          DBI::dbExecute(con, "ALTER TABLE sample_new RENAME TO \"sample\"")

          # ---- Step 8 (cont.): rebuild lab_method, uuid_analyte nullable. ----
          DBI::dbExecute(con, "
            CREATE TABLE lab_method_new (
              uuid VARCHAR PRIMARY KEY,
              uuid_analyte VARCHAR REFERENCES analyte(uuid),
              name VARCHAR,
              method VARCHAR,
              organisation VARCHAR,
              rl_low DOUBLE,
              rl_high DOUBLE,
              reported_as VARCHAR,
              api VARCHAR,
              uuid_project VARCHAR,
              uuid_feature VARCHAR,
              comments VARCHAR
            )")
          DBI::dbExecute(con, "
            INSERT INTO lab_method_new
            SELECT uuid, uuid_analyte, name, method, organisation, rl_low, rl_high,
                   reported_as, api, uuid_project, uuid_feature, comments
            FROM lab_method
          ")
          DBI::dbExecute(con, "DROP TABLE lab_method")
          DBI::dbExecute(con, "ALTER TABLE lab_method_new RENAME TO lab_method")

          # ---- R-13.2: restore units / conversion_constant (additive). ----
          DBI::dbExecute(con, "ALTER TABLE lab_method ADD COLUMN units VARCHAR")
          DBI::dbExecute(con, "ALTER TABLE lab_method ADD COLUMN conversion_constant DOUBLE")
          DBI::dbExecute(con, "
            COMMENT ON COLUMN lab_method.units IS
              'Fallback for interpreting a value when no report-specific unit is
               available. Not a guarantee any given report used this unit; never
               part of the lab_methods identity.'
          ")

          # ---- Step 9: rebuild analysis, FKs against rebuilt tables. ----
          DBI::dbExecute(con, "
            CREATE TABLE analysis (
              uuid VARCHAR PRIMARY KEY,
              uuid_sample VARCHAR REFERENCES \"sample\"(uuid),
              uuid_lab VARCHAR REFERENCES lab_method(uuid),
              value DOUBLE,
              value_chr VARCHAR,
              quantified BOOLEAN,
              rl_low DOUBLE,
              rl_high DOUBLE,
              purpose VARCHAR,
              comments VARCHAR
            )")
          DBI::dbExecute(con, "
            INSERT INTO analysis
            SELECT uuid, uuid_sample, uuid_lab, value, value_chr, quantified,
                   rl_low, rl_high, purpose, comments
            FROM _mig001_analysis_backup
          ")

          # ---- Step 10: recreate the 6 views + write the schema_version marker. ----
          DBI::dbExecute(con, "
            CREATE VIEW v_feature_dates AS
              SELECT f.uuid AS uuid_feature, MIN(s.date) AS date_start, MAX(s.date) AS date_end
              FROM \"sample\" s
              JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
              JOIN feature f ON fa.uuid_feature = f.uuid
              GROUP BY f.uuid
          ")
          DBI::dbExecute(con, "
            CREATE VIEW v_measurement AS
              SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature,
                     f.name AS feature_name, a.value
              FROM analysis a
              JOIN \"sample\" s ON a.uuid_sample = s.uuid
              JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
              JOIN feature f ON fa.uuid_feature = f.uuid
              JOIN lab_method lm ON a.uuid_lab = lm.uuid
              JOIN analyte an ON lm.uuid_analyte = an.uuid
          ")
          DBI::dbExecute(con, "
            CREATE VIEW v_measurement_epa AS
              SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature, a.value
              FROM analysis a
              JOIN \"sample\" s ON a.uuid_sample = s.uuid
              JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
              JOIN feature f ON fa.uuid_feature = f.uuid
              JOIN feature_mask fm ON fm.uuid_feature = f.uuid AND fm.variant = 'epa'
          ")
          DBI::dbExecute(con, "
            CREATE VIEW v_measurement_gas_report AS
              SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature, a.value
              FROM analysis a
              JOIN \"sample\" s ON a.uuid_sample = s.uuid
              JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
              JOIN feature f ON fa.uuid_feature = f.uuid
              JOIN feature_mask fm ON fm.uuid_feature = f.uuid AND fm.variant = 'gas_report'
          ")
          DBI::dbExecute(con, "
            CREATE VIEW v_measurement_long AS
              SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature, a.value
              FROM analysis a
              JOIN \"sample\" s ON a.uuid_sample = s.uuid
              JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
              JOIN feature f ON fa.uuid_feature = f.uuid
              JOIN feature_mask fm ON fm.uuid_feature = f.uuid AND fm.variant = 'long'
          ")
          DBI::dbExecute(con, "
            CREATE VIEW v_measurement_old AS
              SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature, a.value
              FROM analysis a
              JOIN \"sample\" s ON a.uuid_sample = s.uuid
              JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
              JOIN feature f ON fa.uuid_feature = f.uuid
              JOIN feature_mask fm ON fm.uuid_feature = f.uuid AND fm.variant = 'old'
          ")

          DBI::dbExecute(
            con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
            params = list(.mig001_marker_version, recorded_at)
          )

          list(ambiguous_count = ambiguous_count)
        },
        error = function(e) {
          try(DBI::dbExecute(con, "ROLLBACK"), silent = TRUE)
          stop(e)
        }
      )

      DBI::dbExecute(con, "COMMIT")

      counts_after <- mig001_counts_checksum(con)
      logf(
        "Post-migration counts: feature=%d sample=%d analysis=%d lab_method=%d",
        counts_after$feature, counts_after$sample,
        counts_after$analysis, counts_after$lab_method
      )

      # ---- Step 11: hard verify gate. ----
      mig001_verify(counts_before, counts_after)
      logf("Step-11 verify passed: row counts and checksum unchanged.")

      list(
        counts_before = counts_before, counts_after = counts_after,
        ambiguous_count = body$ambiguous_count
      )
    },
    db = db
  )

  logf("001-alias-indirection migrated successfully.")

  invisible(list(
    status = "migrated",
    backup_path = backup_path,
    restore_command = restore_command,
    counts_before = result$counts_before,
    counts_after = result$counts_after,
    ambiguous_count = result$ambiguous_count,
    recorded_at = recorded_at
  ))
}
