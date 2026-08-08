# Operator-run migration: make "one sample per feature per datetime"
# ENFORCEABLE IN THE DATABASE, per Robin's 2026-08-08 ruling 9.
#
#   CREATE UNIQUE INDEX ux_sample_identity
#       ON "sample" (uuid_feature_alias, datetime, uuid_project)
#
# That is the whole change. NO COLUMNS ARE ADDED AND NO ROWS ARE WRITTEN except
# this migration's own `schema_version` marker.
#
# ---- WHY NOT THE SHAPE THAT WAS ORIGINALLY APPROVED ----
#
# The approved design was two new `sample` columns - a denormalised
# `uuid_feature` and a `lab_reference` - carrying
# UNIQUE (uuid_feature, datetime, lab_reference). Phase-1 measurement against a
# copy of the live database (scratchpad/m6c_schema_DESIGN.md and the
# m6c_schema_*.R scripts beside it) found that design does not work:
#
#   * `lab_reference` HAS NO SOURCE for 86.4% of the table. Only 464 of 15,149
#     sample uuids are ALS sample numbers; `project.name` covers 2,053; and
#     `change_log.source_hash` -> `ingest_file.work_order` covers ZERO (every
#     `change_log` row for `tbl = 'sample'` has a NULL source_hash, and
#     `ingest_file` holds 29 rows with 0 non-NULL work orders). The honest
#     value for the other 13,089 rows is NULL.
#   * duckdb TREATS NULLS AS DISTINCT in a unique index. Measured, not assumed:
#     with the index in place, three NULL-`lab_reference` rows sharing one
#     (feature, datetime) all inserted. So the constraint would have been
#     switched OFF for six rows in seven - including every sample the current
#     importer mints, because `.ct_find_or_create_sample()` generates a random
#     uuid and has no work order to store.
#   * `uuid_feature` CANNOT BE KEPT TRUE. It was deliberately dropped by
#     A48/R-11.2 in favour of full alias indirection. Denormalising it back
#     means it must be maintained by every write path - and one of those paths
#     never touches `sample` at all: confirming a dangling alias
#     (`db_update(con, "feature_alias", ...)`, R/feature-alias.R:1011) resolves
#     the alias onto a feature and silently changes the feature of every sample
#     sitting on it. duckdb has no triggers. Propagating it by hand needs the
#     008 FK detach/reattach dance per sample (duckdb refuses to UPDATE a
#     `sample` row while an `analysis` references it), i.e. a non-atomic window
#     inside confirm_feature_aliases(). A denormalised column that silently
#     goes stale is worse than no column.
#
# `sample.uuid_project` is already the work-order handle those two columns were
# reaching for, and it is better at the job: it is populated on 15,149 of
# 15,149 rows, it is set on every insert by `.ct_ensure_project()` (which finds
# or creates, and never returns NA), and it needs no maintenance because it is
# a stored fact rather than a copy of one.
#
# ---- WHAT THE KEY MEANS, AND WHAT IT GIVES UP ----
#
# `(uuid_feature_alias, datetime, uuid_project)` reads: ONE SAMPLE PER ALIAS PER
# INSTANT PER PROJECT. Measured on the live database, pre-008 and post-008
# alike, it has ZERO violations across all 15,149 rows.
#
# It is vacuous on exactly 2 rows - the two whose `datetime` is NULL (their
# `date` is NULL too). A sample with no datetime has no instant to be unique
# at; that is the honest exemption. Compare 13,089 for the approved design.
#
# IT IS KEYED ON THE ALIAS, NOT THE FEATURE, and that is a real - measured
# empty - concession. Two DIFFERENT alias names resolving to one feature would
# slip through. Today: 895 features, 1,994 aliases, and ZERO features recorded
# under two different alias names. Two features (B.S01, K.E02) carry DUPLICATE
# ALIAS ROWS OF THE SAME NAME - same `name`, same `alias_key`, differing only
# in `kind` (self vs transcription_error), worth 3 samples between them. That
# is the separate E.8/F.19 duplicate-arm registry defect that
# `merge_identity_aliases()` exists to collapse (008's header names the same
# two rows), NOT two names for one feature, and it is not this index's job.
#
# The reachable way to create a genuine two-alias collision is
# `confirm_feature_aliases()` resolving a pending alias onto a feature that
# already holds samples. That path ALREADY has a mechanism - the
# `kind = "sample_collision"`, `subkind = "same_alias"` review rows at
# R/feature-alias.R:907 - so the case is itemised and auditable in R rather
# than silently lost. A database constraint could not handle it gracefully
# anyway: it would surface as a raw driver error mid-confirmation.
#
# ---- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO ----
#
# IT DOES NOT ADD `sample.uuid_feature` OR `sample.lab_reference`. See above.
#
# IT DOES NOT MAKE (feature, datetime) UNIQUE. 008's header explains why no
# migration can: after 008's two fixes, 14 groups holding 44 samples still
# share a (feature, datetime), every one of them a distinct ALS work order,
# all stamped 00:00 because the XTAB format has no time field. This index
# separates exactly those 44 by their work order, which is the true difference
# between them - it does not invent 44 clock times.
#
# IT DOES NOT FIX `sample.date`. Phase 1 found, and the coordinator confirmed
# independently, that `sample.date` is stored as AEST midnight converted to UTC
# (14:00, or 13:00 in AEDT, on the PREVIOUS calendar day) for 14,456 of 15,149
# rows, while `.ct_find_or_create_sample()` writes naive UTC midnight - only 36
# rows use this pipeline's convention. Asked with each sample's true AEST
# calendar day, `.ct_existing_sample_uuid()` found 0 of 400 real samples;
# asked with the day `CAST(date AS DATE)` reads back, it found 400 of 400. So a
# re-ingest of legacy data would fail to reuse the existing sample and mint a
# duplicate EVERY TIME.
#
# THAT DEFECT IS TOTAL AND LATENT: it has never fired. There are zero
# violations of this index's key today, and it did NOT create the Family A
# duplicates 008 deletes (all 10 of those samples carry the legacy
# AEST-as-UTC `date`, so both rows of each pair are legacy loads). It is a
# pre-existing defect in the date convention, independent of and larger than
# this migration, and it needs its own ruling. What this index does is turn
# that silent duplication into a visible failure the moment it is attempted -
# which is the whole point of enforcing the invariant in the database.
#
# ---- WHY AN INDEX AND NOT A CONSTRAINT ----
#
# Measured on duckdb 1.4.1 (scratchpad/m6c_schema_duckdb_probe.R):
#
#   ALTER TABLE ... ADD CONSTRAINT ... UNIQUE  -> "No support for that ALTER
#                                                  TABLE option yet!"
#   ALTER TABLE ... DROP CONSTRAINT            -> same (this is A49)
#   CREATE UNIQUE INDEX on a populated table   -> OK
#   ... on the real 15,149-row `sample`        -> OK, 0.01s, no file growth
#   DROP INDEX                                 -> OK
#
# So the index is the only mechanism available, and it is the better one: it is
# a metadata operation over existing rows, so `sample` is never rewritten and
# `analysis`'s inbound FK is never in play. NO TABLE REBUILD, and therefore
# none of the FK cost that made the approved design expensive.
#
# IT IS ALSO REVERSIBLE - `DROP INDEX ux_sample_identity` - which nothing built
# with ADD CONSTRAINT would be. That is what makes it safe to ship ahead of
# Robin re-confirming the changed shape.
#
# ---- TRANSACTION SHAPE, AND WHY THE PROBES STAND ALONE ----
#
# Measured (scratchpad/m6c_schema_txprobe.R), because all three surprised the
# first draft:
#
#   * CREATE UNIQUE INDEX works inside a transaction, and ROLLBACK UNDOES IT.
#     That is what lets the preflight below prove the index builds and bites
#     while committing nothing.
#   * A CONSTRAINT ERROR POISONS THE WHOLE TRANSACTION. After the duplicate is
#     rejected, every subsequent statement on that connection - even a SELECT -
#     fails with "Current transaction is aborted". So the rejection probe
#     CANNOT live inside the main transaction, and cannot be caught and
#     recovered from: the only legal next statement is ROLLBACK.
#   * duckdb 1.4.1 HAS NO SAVEPOINTS ("Parser Error: syntax error at or near
#     SAVEPOINT"), so there is no nested-rollback way around that.
#
# Hence three phases, in this order:
#
#   1. PREFLIGHT (`.mig009_preflight()`), read-only in effect: its own
#      transaction, always rolled back. Builds the index and proves it rejects
#      a duplicate. Runs BEFORE the backup, so a doomed run leaves no stray
#      copy - and, unlike a precondition query, it proves the property BY
#      CONSTRUCTION rather than by re-asking the same question a different way.
#   2. THE MAIN TRANSACTION: create the index for real, write the marker, and
#      run the SAFETY gate.
#   3. POST-COMMIT PROOF (`.mig009_verify_enforces()`): the SUCCESS half, asked
#      of the COMMITTED, persisted index rather than an uncommitted one.
#
# ---- ORDERING ----
# INDEPENDENT of 005, 006, 007 and 008. Measured: the key has zero violations
# on the live database WITHOUT 008 having run. It can go before or after any of
# them. (008 is still worth running for its own reasons - it deletes five
# genuine duplicate loads and un-breaks B.L05 - but this index does not need
# it, and does not enforce it.)
#
# NEVER invoked by package code (A50). Run it from a session where the package
# was loaded with `devtools::load_all(".")`.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/009-sample-identity-index.R", envir = env)
#   env$mig009_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"),
#                  dry_run = TRUE)

.mig009_marker_version <- 1009L
.mig009_actor <- "009-sample-identity-index"

.mig009_default <- function(x, default) if (is.null(x)) default else x

# ---- the change, declaratively -----------------------------------------------
# Named by NATURAL KEY - the table and its COLUMN NAMES - never by uuid and
# never by a stored DDL string. Everything else is proved at run time.

.mig009_index_name <- "ux_sample_identity"
.mig009_table <- "sample"
.mig009_key_cols <- c("uuid_feature_alias", "datetime", "uuid_project")

#' Guard: this migration is run from a `devtools::load_all(".")` session
#' @keywords internal
#' @noRd
.mig009_require_internals <- function() {
  needed <- c("st_connect", "with_db_write", "db_transaction")
  missing <- needed[!vapply(needed, exists, logical(1), mode = "function")]
  if (length(missing) > 0) {
    cli::cli_abort(
      "009-sample-identity-index: {paste(missing, collapse = ', ')} {?is/are} not
       visible. Run this from a session where the package was loaded with
       {.code devtools::load_all(\".\")} - see the file header.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

#' The `CREATE UNIQUE INDEX` statement, built from the declarative spec
#'
#' Built rather than stored so the spec above is the single source of truth -
#' a hand-written SQL literal beside a column list is two things that can
#' disagree.
#' @keywords internal
#' @noRd
.mig009_create_sql <- function() {
  sprintf('CREATE UNIQUE INDEX %s ON "%s" (%s)',
          .mig009_index_name, .mig009_table,
          paste(sprintf('"%s"', .mig009_key_cols), collapse = ", "))
}

# ---- preconditions ----------------------------------------------------------

#' Does the target table have every key column?
#'
#' Asked before anything else, because `CREATE UNIQUE INDEX` on a missing
#' column fails with a Binder error that says nothing about which migration
#' assumed what.
#' @keywords internal
#' @noRd
.mig009_check_columns <- function(con) {
  if (!DBI::dbExistsTable(con, .mig009_table)) {
    cli::cli_abort(
      "009-sample-identity-index: there is no {sQuote(.mig009_table)} table in
       this database.",
      class = "sampletidy_error"
    )
  }
  have <- DBI::dbListFields(con, .mig009_table)
  missing <- setdiff(.mig009_key_cols, have)
  if (length(missing) > 0) {
    cli::cli_abort(
      "009-sample-identity-index: {sQuote(.mig009_table)} has no column(s)
       {paste(sQuote(missing), collapse = ', ')}. This migration keys on
       {paste(sQuote(.mig009_key_cols), collapse = ', ')}; refusing.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

#' Is an index of this name already present?
#' @keywords internal
#' @noRd
.mig009_index_exists <- function(con) {
  hit <- DBI::dbGetQuery(
    con, "SELECT index_name FROM duckdb_indexes() WHERE index_name = ?",
    params = list(.mig009_index_name)
  )
  nrow(hit) > 0
}

#' The groups that VIOLATE the key, as rows a human can act on.
#'
#' IT ASKS EXACTLY THE QUESTION `CREATE UNIQUE INDEX` WILL ASK - no stricter -
#' and getting that wrong cost a test. duckdb's two NULL semantics disagree,
#' and the disagreement matters here:
#'
#'   * a duckdb UNIQUE INDEX treats NULLs as DISTINCT - three rows with a NULL
#'     key column at one (alias, datetime) all inserted;
#'   * duckdb's GROUP BY treats NULLs as EQUAL - `GROUP BY x` over two NULL
#'     rows yields ONE group of 2.
#'
#' So a plain `GROUP BY` over the key columns reports collisions the index
#' would happily accept. The first draft did exactly that and called it a
#' virtue - "a precondition stricter than the constraint can only refuse a
#' migration that would have succeeded". THAT REASONING IS WRONG, and the
#' fixture that caught it is the test named "NULL key columns do NOT count as a
#' violation": two project-less samples at one alias and instant made the
#' migration REFUSE A DATABASE IT COULD HAVE MIGRATED, with an error telling
#' the operator to fix data the constraint does not care about. A gate that
#' blocks what the constraint permits is a gate that gets deleted.
#'
#' It also made the preflight unreachable. `.mig009_preflight()` settles the
#' question by actually building the index - that is the ground truth - and a
#' precondition that refuses first, on different semantics, means the ground
#' truth never runs.
#'
#' Hence the `IS NOT NULL` filter: rows with a NULL in any key column are
#' UNCONSTRAINED by this index and are excluded from the count, exactly as
#' duckdb will exclude them. That vacuity is real and documented in the file
#' header - 2 rows on the live database.
#' @keywords internal
#' @noRd
.mig009_violations <- function(con) {
  keys <- paste(sprintf('"%s"', .mig009_key_cols), collapse = ", ")
  not_null <- paste(sprintf('"%s" IS NOT NULL', .mig009_key_cols), collapse = " AND ")
  DBI::dbGetQuery(
    con,
    sprintf('SELECT %s, COUNT(*) AS n, MIN(uuid) AS example_uuid
               FROM "%s" WHERE %s
              GROUP BY %s HAVING COUNT(*) > 1
              ORDER BY n DESC, example_uuid',
            keys, .mig009_table, not_null, keys)
  )
}

#' Refuse if today's data cannot satisfy the key, NAMING the offenders.
#'
#' A bare "cannot create index" would send the operator to duckdb's error text,
#' which reports ONE duplicate key and stops. The whole point of running this
#' before the backup is that the operator learns everything that is wrong in
#' one go.
#' @keywords internal
#' @noRd
.mig009_check_no_violations <- function(con) {
  v <- .mig009_violations(con)
  if (nrow(v) > 0) {
    shown <- utils::head(v, 10)
    lines <- sprintf("  %s = %s -> %d samples (e.g. %s)",
                     paste(.mig009_key_cols, collapse = " / "),
                     apply(shown[, .mig009_key_cols, drop = FALSE], 1,
                           function(r) paste(r, collapse = " / ")),
                     shown$n, shown$example_uuid)
    # Bound to locals: cli reads a `{}` expression STARTING WITH A DOT as a
    # style name, not a value (cli >= 3.4.0), so `{.mig009_index_name}` aborts
    # with an rlib_error about an invalid cli literal instead of this gate's
    # promised `sampletidy_error`. Fourth time this trap has been sprung across
    # 006/007/008/009; the tests have caught it every time.
    idx <- .mig009_index_name
    cols <- paste(.mig009_key_cols, collapse = ", ")
    cli::cli_abort(
      c("009-sample-identity-index: {nrow(v)} group{?s} holding {sum(v$n)} samples
         violate ({cols}), so the unique index {idx} cannot be created.",
        "i" = paste(lines, collapse = "\n"),
        "x" = "Give the colliding samples their real times, or separate them onto
               the projects or features they actually belong to, then re-run."),
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

#' Every precondition, for the dry run and the pre-backup gate
#' @keywords internal
#' @noRd
.mig009_check_preconditions <- function(con) {
  .mig009_check_columns(con)
  if (.mig009_index_exists(con)) {
    idx <- .mig009_index_name
    cli::cli_abort(
      "009-sample-identity-index: an index named {idx} already exists, but this
       migration's {.field schema_version} marker does not. Refusing rather than
       guessing whether it is this migration's index or something else's - check
       it with {.code SELECT * FROM duckdb_indexes()} and drop it if it is a
       leftover from a failed run.",
      class = "sampletidy_error"
    )
  }
  .mig009_check_no_violations(con)
  invisible(TRUE)
}

# ---- the enforcement probe --------------------------------------------------

#' A `sample` row that would duplicate an existing one on the key, or NULL.
#'
#' Returns the existing row's key values plus a fresh uuid. Real data, so the
#' probe tests the index against the shape the database actually holds.
#' @keywords internal
#' @noRd
.mig009_probe_row <- function(con) {
  cols <- paste(sprintf('"%s"', .mig009_key_cols), collapse = ", ")
  hit <- DBI::dbGetQuery(
    con,
    sprintf('SELECT %s FROM "%s"
              WHERE %s
              ORDER BY uuid LIMIT 1',
            cols, .mig009_table,
            paste(sprintf('"%s" IS NOT NULL', .mig009_key_cols), collapse = " AND "))
  )
  if (nrow(hit) == 0) return(NULL)
  hit
}

#' Prove the index REJECTS a duplicate, by making one.
#'
#' THIS IS THE SUCCESS HALF, and it is an INSERT rather than a catalogue read
#' on purpose. `duckdb_indexes()` reporting `is_unique = TRUE` proves an index
#' was named; it does not prove it bites. Reading back the DDL you just wrote
#' is not evidence - it is the same statement, asked twice.
#'
#' ALWAYS ROLLS BACK. The probe row never survives, whichever way it goes:
#' measured, ROLLBACK removes both a successful probe insert and the index
#' itself when the preflight created one.
#'
#' `con` MUST NOT be inside a transaction - this opens its own, because a
#' constraint error poisons the enclosing one irrecoverably (no savepoints in
#' duckdb 1.4.1; see the file header).
#'
#' @param create_first if TRUE, build the index inside the probe transaction
#'   too, so the whole thing is proved without committing anything.
#' @return invisible(TRUE); throws `sampletidy_error` if the duplicate was
#'   ACCEPTED, i.e. if the index does not actually enforce.
#' @keywords internal
#' @noRd
.mig009_probe_rejects_duplicate <- function(con, create_first = FALSE) {
  row <- .mig009_probe_row(con)
  if (is.null(row)) {
    idx <- .mig009_index_name
    cli::cli_abort(
      "009-sample-identity-index: {.field sample} holds no row with a non-NULL
       value in every key column, so there is nothing to duplicate and the
       {idx} index cannot be PROVED to enforce anything. Refusing rather than
       reporting success for a check that could not run.",
      class = "sampletidy_error"
    )
  }

  DBI::dbExecute(con, "BEGIN TRANSACTION")
  # `add = TRUE, after = FALSE` so the ROLLBACK runs FIRST if anything below
  # also registers cleanup. A poisoned transaction accepts nothing except
  # ROLLBACK, so this must not be conditional on the probe's outcome.
  on.exit(try(DBI::dbExecute(con, "ROLLBACK"), silent = TRUE), add = TRUE, after = FALSE)

  if (isTRUE(create_first)) {
    DBI::dbExecute(con, .mig009_create_sql())
  }

  cols <- c("uuid", .mig009_key_cols)
  sql <- sprintf('INSERT INTO "%s" (%s) VALUES (%s)',
                 .mig009_table,
                 paste(sprintf('"%s"', cols), collapse = ", "),
                 paste(rep("?", length(cols)), collapse = ", "))
  params <- c(list(paste0("mig009-probe-", uuid::UUIDgenerate())),
              lapply(.mig009_key_cols, function(k) row[[k]][[1]]))

  accepted <- tryCatch({
    DBI::dbExecute(con, sql, params = params)
    TRUE
  }, error = function(e) FALSE)

  if (accepted) {
    idx <- .mig009_index_name
    cols_txt <- paste(.mig009_key_cols, collapse = ", ")
    cli::cli_abort(
      c("009-sample-identity-index: the {idx} index DOES NOT ENFORCE.",
        "i" = "A row duplicating an existing sample on ({cols_txt}) was ACCEPTED.",
        "x" = "The index exists but the constraint is not doing anything, so
               this migration has not achieved what it exists to do."),
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

#' PREFLIGHT: build the index and prove it bites, committing nothing.
#'
#' Runs before the backup. Because ROLLBACK undoes a CREATE INDEX (measured),
#' this proves the real statement succeeds against the real data AND that the
#' resulting index rejects a real duplicate, while leaving the database exactly
#' as it was found.
#' @keywords internal
#' @noRd
.mig009_preflight <- function(con) {
  .mig009_probe_rejects_duplicate(con, create_first = TRUE)
  # DELIBERATELY UNREACHABLE ON duckdb 1.4.1, AND KEPT ANYWAY - recorded here
  # because the honest thing is to say which of these gates is tested and which
  # is not. Mutation M12 (deleting this check) SURVIVED the suite, and it will
  # survive any suite: ROLLBACK does undo a CREATE INDEX on this duckdb, so the
  # failing branch cannot be reached and no fixture can reach it.
  #
  # 008 deleted its equivalent unreachable check (the "did they all come back"
  # count) on exactly this reasoning, and that was right there because the
  # property was already asserted by a different mechanism. THE DIFFERENCE HERE
  # is what the branch protects against: not a bug in this file, but a change
  # in duckdb. If a future version made CREATE INDEX non-transactional, the
  # preflight - which runs during a DRY RUN - would silently migrate the
  # database instead of rehearsing. That is a failure mode worth a two-line
  # tripwire even though today it can only ever be dead code.
  #
  # The property IS covered by tests, just not by this branch: "dry_run writes
  # nothing ... and leaves no index behind" and "the probe leaves NO trace"
  # both assert it from outside, against the real database.
  if (.mig009_index_exists(con)) {
    idx <- .mig009_index_name
    cli::cli_abort(
      "009-sample-identity-index: the preflight's {idx} index SURVIVED its
       rollback. This migration's whole safety argument rests on ROLLBACK
       undoing a CREATE INDEX; refusing rather than proceeding on a database
       where it does not.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

#' POST-COMMIT: the same proof, asked of the committed index.
#' @keywords internal
#' @noRd
.mig009_verify_enforces <- function(con) {
  if (!.mig009_index_exists(con)) {
    idx <- .mig009_index_name
    cli::cli_abort(
      "009-sample-identity-index verify failed: no index named {idx} exists
       after the migration committed.",
      class = "sampletidy_error"
    )
  }
  meta <- DBI::dbGetQuery(
    con, "SELECT table_name, is_unique FROM duckdb_indexes() WHERE index_name = ?",
    params = list(.mig009_index_name)
  )
  if (!isTRUE(as.logical(meta$is_unique[[1]]))) {
    idx <- .mig009_index_name
    cli::cli_abort(
      "009-sample-identity-index verify failed: {idx} exists but is not UNIQUE.",
      class = "sampletidy_error"
    )
  }
  if (!identical(as.character(meta$table_name[[1]]), .mig009_table)) {
    cli::cli_abort(
      "009-sample-identity-index verify failed: the index is on
       {sQuote(meta$table_name[[1]])}, not {sQuote(.mig009_table)}.",
      class = "sampletidy_error"
    )
  }
  # The catalogue agrees. Now the only check that means anything.
  .mig009_probe_rejects_duplicate(con, create_first = FALSE)
  invisible(TRUE)
}

# ---- verify: the SAFETY half ------------------------------------------------

#' Row counts + a content checksum over every table, discovered from the
#' database rather than listed.
#'
#' Same shape as `mig008_counts_checksum()`, and the same two lessons are
#' baked in:
#'
#'   * BASE TABLES AND VIEWS ARE SEPARATED. `dbListTables()` returns both, and
#'     008's first version checksummed the five reporting views too - then
#'     failed itself because they had changed, which for 008 was the intended
#'     effect. THIS migration writes no rows, so the views must not move
#'     either, and `mig009_verify()` checks their counts as well.
#'   * The sum is cast to VARCHAR IN SQL. Returned as a double it arrives as
#'     "8.9e+23" - a checksum with a hole in it.
#'
#' ONLY `schema_version` IS SKIPPED, and that is the one difference from 008.
#' 008 also skipped `change_log`, because it wrote change_log rows. 009 writes
#' NOTHING but its own marker, so change_log is INSIDE the safety sweep - if
#' this migration ever grows a `db_*` call, the gate fails.
#' @keywords internal
mig009_counts_checksum <- function(con) {
  skip <- c("schema_version")
  meta <- DBI::dbGetQuery(
    con,
    "SELECT table_name, table_type FROM information_schema.tables
      WHERE table_schema = 'main' ORDER BY table_name")
  meta <- meta[!(meta$table_name %in% skip) & !grepl("^_st_", meta$table_name), , drop = FALSE]

  tables <- list()
  for (t in meta$table_name[meta$table_type == "BASE TABLE"]) {
    n <- as.integer(DBI::dbGetQuery(con, sprintf('SELECT COUNT(*) n FROM "%s"', t))$n)
    cols <- DBI::dbListFields(con, t)
    expr <- paste(sprintf('COALESCE(CAST("%s" AS VARCHAR), \'\\x00\')', cols),
                  collapse = " || '|' || ")
    h <- DBI::dbGetQuery(
      con, sprintf('SELECT CAST(COALESCE(SUM(HASH(%s)), 0) AS VARCHAR) h FROM "%s"', expr, t)
    )$h
    tables[[t]] <- n
    tables[[paste0(t, "_checksum")]] <- as.character(h)
  }

  views <- list()
  for (v in meta$table_name[meta$table_type == "VIEW"]) {
    views[[v]] <- as.integer(DBI::dbGetQuery(con, sprintf('SELECT COUNT(*) n FROM "%s"', v))$n)
  }
  list(tables = tables, views = views)
}

#' The SAFETY half: NOTHING moved. No exceptions.
#'
#' 008 had to exempt `sample` and `analysis` and check them by delta, because
#' changing them was its job. This migration changes NO ROWS AT ALL, so the
#' gate is total: every base table byte-identical by content checksum, and
#' every view's row count unchanged too. There is no exemption list to drift.
#'
#' @param before,after `mig009_counts_checksum()`-shaped lists.
#' @return invisible(TRUE); throws otherwise.
mig009_verify <- function(before, after) {
  if (!identical(names(before$tables), names(after$tables)) ||
      !identical(names(before$views), names(after$views))) {
    cli::cli_abort(
      "009-sample-identity-index verify failed: the before/after count structures
       differ - a table or view was created or dropped.",
      class = "sampletidy_error"
    )
  }
  bad <- names(before$tables)[!vapply(
    names(before$tables),
    function(n) identical(before$tables[[n]], after$tables[[n]]), logical(1))]
  if (length(bad) > 0) {
    cli::cli_abort(
      "009-sample-identity-index verify failed: this migration writes NO rows to
       any table, but {paste(bad, collapse = ', ')} changed.",
      class = "sampletidy_error"
    )
  }
  bad_v <- names(before$views)[!vapply(
    names(before$views),
    function(n) identical(before$views[[n]], after$views[[n]]), logical(1))]
  if (length(bad_v) > 0) {
    cli::cli_abort(
      "009-sample-identity-index verify failed: this migration writes NO rows, so
       no reporting view can move, but {paste(bad_v, collapse = ', ')} changed.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

#' Fold the write-ahead log back into the database file.
#'
#' NOT COSMETIC, and not only for the tests. duckdb leaves a `.wal` beside the
#' database after any write, and A READ-ONLY CONNECTION CANNOT REPLAY ONE -
#' `dbConnect(..., read_only = TRUE)` fails with "Failure while replaying WAL
#' file ... Could not write file". So a migration that returns without
#' checkpointing can leave the database temporarily unopenable by every
#' read-only consumer in the package, including `st_connect(db,
#' read_only = TRUE)`, until something happens to open it read-write.
#'
#' Measured both ways: without the CHECKPOINT the `.wal` survives the
#' disconnect and a read-only reopen fails; with it, the `.wal` is gone and the
#' reopen succeeds. `mig009_backup()` already checkpoints for the same reason -
#' a backup taken with a live WAL would be missing the tail.
#' @keywords internal
#' @noRd
.mig009_checkpoint <- function(con) {
  DBI::dbExecute(con, "CHECKPOINT")
  invisible(TRUE)
}

# ---- backup -----------------------------------------------------------------

.mig009_backup_counts <- function(con) {
  list(
    sample = as.integer(DBI::dbGetQuery(con, 'SELECT COUNT(*) n FROM "sample"')$n),
    analysis = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n),
    feature_alias = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_alias")$n)
  )
}

mig009_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig009_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir,
                    sprintf("monitoring_pre-009-sample-identity-index_%sZ.duckdb", ts))

  live_counts <- with_db_write(
    function(con) {
      DBI::dbExecute(con, "CHECKPOINT")
      counts <- .mig009_backup_counts(con)
      ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)),
                     error = function(e) FALSE)
      if (!isTRUE(ok)) {
        cli::cli_abort("{db}: failed to write backup copy to {dest}.",
                       class = "sampletidy_error")
      }
      counts
    },
    db = db
  )

  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE),
                         error = function(e) NULL)
  if (is.null(verify_con)) {
    cli::cli_abort("{db}: backup verification failed - cannot open {dest} read-only.",
                   class = "sampletidy_error")
  }
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig009_backup_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - row counts differ between live DB and {dest}.",
                   class = "sampletidy_error")
  }
  dest
}

# ---- mig009_run() -----------------------------------------------------------

#' Run (or dry-run) the 009-sample-identity-index migration
#'
#' Never invoked by package code (A50).
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory for the pre-migration backup.
#' @param dry_run if `TRUE`, run every gate including the full preflight
#'   (which commits nothing), write nothing, take no backup.
#' @param .now inject a POSIXct instead of `Sys.time()`.
#' @return invisible list(status, backup_path, restore_command, index_name,
#'   key_columns, n_samples, counts_before, counts_after, recorded_at).
mig009_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  .mig009_require_internals()

  # ---- Step 0: idempotency marker ----
  marker_con <- st_connect(db, read_only = TRUE)
  if (!("schema_version" %in% DBI::dbListTables(marker_con))) {
    DBI::dbDisconnect(marker_con, shutdown = TRUE)
    cli::cli_abort(
      "{db}: no schema_version table found - ensure_schema() has never been applied
       to this database, so 009-sample-identity-index cannot check its own marker.",
      class = "sampletidy_error"
    )
  }
  marker <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig009_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE)
  )
  if (nrow(marker) > 0) {
    recorded_at <- marker$applied_at[[1]]
    logf("009-sample-identity-index already applied at %s; nothing to do.", format(recorded_at))
    read_con <- st_connect(db, read_only = TRUE)
    counts <- tryCatch(mig009_counts_checksum(read_con),
                       finally = DBI::dbDisconnect(read_con, shutdown = TRUE))
    return(invisible(list(
      status = "already_migrated", backup_path = NA_character_,
      restore_command = NA_character_, index_name = .mig009_index_name,
      key_columns = .mig009_key_cols, n_samples = NA_integer_,
      counts_before = counts, counts_after = counts, recorded_at = recorded_at
    )))
  }

  # ---- dry run: every gate INCLUDING the preflight, no write, no backup ----
  # The preflight needs a WRITE connection (it opens a transaction and creates
  # an index) but commits nothing - it always rolls back. That is what makes a
  # dry run here worth more than a read-only one: it proves the actual DDL
  # succeeds against the actual data, rather than proving a SELECT agrees.
  if (isTRUE(dry_run)) {
    out <- with_db_write(
      function(con) {
        .mig009_check_preconditions(con)
        .mig009_preflight(con)
        out <- list(counts = mig009_counts_checksum(con),
                    n = as.integer(DBI::dbGetQuery(con, 'SELECT COUNT(*) n FROM "sample"')$n))
        .mig009_checkpoint(con)
        out
      },
      db = db
    )
    logf("DRY RUN: preflight built %s on (%s) over %d samples, proved it rejects a duplicate, and rolled it back.",
         .mig009_index_name, paste(.mig009_key_cols, collapse = ", "), out$n)
    logf("DRY RUN: no backup taken, no writes made to %s.", db)
    return(invisible(list(
      status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
      index_name = .mig009_index_name, key_columns = .mig009_key_cols,
      n_samples = out$n, counts_before = out$counts, counts_after = NA, recorded_at = NA
    )))
  }

  # ---- Step 1: preconditions AND the full preflight, BEFORE the backup, so a
  # run that could never have succeeded leaves no stray copy behind. Both are
  # re-checked inside the transaction, because the database can move between
  # these two moments. ----
  with_db_write(
    function(con) {
      .mig009_check_preconditions(con)
      .mig009_preflight(con)
      .mig009_checkpoint(con)
    },
    db = db
  )
  logf("Preflight passed: %s builds on this data and rejects a duplicate (rolled back).",
       .mig009_index_name)

  # ---- Step 2: back up and verify, before any write ----
  backup_path <- mig009_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)

  recorded_at <- .mig009_default(.now, Sys.time())

  result <- with_db_write(
    function(con) {
      counts_before <- mig009_counts_checksum(con)
      n_samples <- as.integer(DBI::dbGetQuery(con, 'SELECT COUNT(*) n FROM "sample"')$n)

      body <- db_transaction(con, function(con) {
        # Re-checked here rather than only in the gate above, because the
        # database can move between the two moments. NOT the preflight - that
        # one cannot run inside this transaction (a rejected duplicate would
        # poison it irrecoverably; see the file header).
        .mig009_check_preconditions(con)

        DBI::dbExecute(con, .mig009_create_sql())
        DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                       params = list(.mig009_marker_version, recorded_at))

        counts_after <- mig009_counts_checksum(con)
        mig009_verify(counts_before, counts_after)
        list(counts_after = counts_after)
      })

      # ---- Step 3: the SUCCESS half, on the COMMITTED index, in its own
      # transaction. Must be outside the one above: a constraint error poisons
      # a duckdb transaction irrecoverably and there are no savepoints. ----
      .mig009_verify_enforces(con)
      .mig009_checkpoint(con)

      list(counts_before = counts_before, counts_after = body$counts_after,
           n_samples = n_samples)
    },
    db = db
  )

  logf("Verify passed: %s is UNIQUE on (%s) over %d samples, and rejects a duplicate.",
       .mig009_index_name, paste(.mig009_key_cols, collapse = ", "), result$n_samples)
  logf("009-sample-identity-index migrated successfully.")
  logf("Reversible if needed: DROP INDEX %s;", .mig009_index_name)

  invisible(list(
    status = "migrated", backup_path = backup_path, restore_command = restore_command,
    index_name = .mig009_index_name, key_columns = .mig009_key_cols,
    n_samples = result$n_samples, counts_before = result$counts_before,
    counts_after = result$counts_after, recorded_at = recorded_at
  ))
}
