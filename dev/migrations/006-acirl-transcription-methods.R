# A79 step 6a - operator-run migration: give every ACIRL TRANSCRIPTION LABEL an
# ACIRL `lab_method` that RESOLVES, so the transcription import can tell an
# ACIRL copy of an ALS number from a genuine field reading.
#
# THE DEFECT THIS PREVENTS (it does not exist yet - this migration exists so it
# never does). Analyte resolution is PER ORGANISATION: `.rc_resolve_one_analyte()`
# (R/reconcile.R:1286) filters candidate `lab_method` rows on
# `organisation == org` in BOTH its exact branch and its folded branch. An ALS
# `lab_method` named `Calcium` therefore does NOT resolve an incoming ACIRL row
# labelled `Calcium`. Measured 2026-08-02 over the real corpus: of the 215
# distinct transcription labels the adapter emits, exactly ONE has an ACIRL
# `lab_method` today. So importing the transcriptions with the registry as it
# stands would mint 214 DANGLING methods (`uuid_analyte IS NULL`,
# R/commit.R:1068 `.ct_materialise_lab_methods()`).
#
# A dangling method has no analyte, and A79's supersession
# (`.rc_acirl_supersession()`, R/reconcile.R:2144) matches an ACIRL transcription
# against its ALS twin ON THE RESOLVED ANALYTE UUID. No analyte, no twin test.
# All 34,137 candidate rows in `unprocessed/` would commit as provisional
# duplicates of ALS data that is ALREADY in the database, with nothing able to
# supersede them - the silent-duplicate failure mode A79 exists to invert. That
# is why the plan was REORDERED so this pass runs BEFORE the import, not after.
#
# (A whole-corpus pass emits 38,450 candidate rows, but that figure DOUBLE
# COUNTS: 10 workbooks exist in both `unprocessed/` and `processed/`, so only
# 34,024 (file, source_ref) pairs are distinct. 34,137 is the `unprocessed/`
# count - what a 6c ingest of that directory would actually see - and all 215
# labels occur there. Recorded because the 38,450 figure is the one that turns
# up in the earlier scratchpad measurements.)
#
# WHAT IT DOES. One `lab_method` per mapping row: `organisation = 'ACIRL'`,
# `name` = the label verbatim, `method` = NULL, `uuid_analyte` = the mapped
# analyte. It writes NOTHING else - no `analysis` row is created, updated or
# read for content, and no existing `lab_method` is touched.
#
# THREE THINGS MEASUREMENT SETTLED (scratchpad/m6a_*.R, all read-only):
#
#   (a) `method = NULL` IS THE POINT, not an omission. `.rc_lab_kind()`
#       (R/reconcile.R:1977) classifies an ACIRL row as `acirl_transcription`
#       if and only if its method is NULL; a non-NULL method makes it
#       `acirl_own_lab` (ACIRL's own dust work) and exempt from supersession
#       forever. The ACIRL water sheets carry no method codes at all - the
#       adapter's `als_candidates` frame has no `method_raw` column - so NULL
#       is also what the import itself would have written.
#
#   (b) `units = NULL`, DELIBERATELY, against the first instinct. It looks
#       right to record the corpus units, and `.ct_materialise_lab_methods()`
#       (R/commit.R:1125) would have. But `lab_method.units` is INERT for value
#       conversion: `.rc_resolve_units_values()` (R/reconcile.R:1590) converts
#       from the INCOMING ROW's `units_raw` to the ANALYTE's units and never
#       reads the method's. Its only other use is the units-drift sighting at
#       R/commit.R:1096, which fires only for DANGLING methods - which these are
#       not. Measured: 358 of the 359 live `lab_method` rows carry NULL units,
#       including all 19 existing ACIRL ones. Writing units here would invent a
#       convention the database does not have, for a column nothing reads.
#
#   (c) NO LABEL COLLIDES WITH A FIELD METHOD. A minted transcription method
#       must not shadow an ACIRL `field` method, or a genuine field reading
#       would start classifying as a transcription and become deletable.
#       Measured across the whole corpus: the transcription-label set and the
#       field-label set are DISJOINT (0 of 215). The mapping gate below still
#       refuses a collision rather than trusting that measurement to stay true.
#
# LEAVING A LABEL OUT OF THE MAPPING ONLY STOPS IT RESOLVING - IT DOES NOT STOP
# IT BEING IMPORTED, and reading it the other way round would be a costly
# mistake. `.rc_resolve_analytes()` (R/reconcile.R:1337) drops a row from `kept`
# for exactly ONE status: `held`, meaning the analyte label is NA or folds to
# nothing. `miss` keeps the row with `analyte_pending = TRUE`, and COMMIT then
# mints a dangling `lab_method` for it. Measured over all 7 excluded labels
# (scratchpad/m6a_excluded_fate.R): 7 rows in, 7 kept, 6 review items. A label
# that must genuinely not be imported needs an ADAPTER-level exclusion, the way
# R-6.7 drops the site-metadata labels - not an omission here.
#
# WHAT IT DELIBERATELY DOES NOT DO:
#   * It does not CREATE analytes. Every `uuid_analyte` must already exist. A
#     label needing a new analyte (e.g. the `Decachlorobiphenyl` surrogate) is
#     left out of the mapping and handled with `add_analyte()` first.
#   * It does not import, delete or re-value a single `analysis` row.
#   * It does not decide which labels are worth linking. That judgement lives in
#     the mapping file, which is reviewable data, not code.
#
# NEVER invoked by package code (A50) - an operator runs it directly, from an R
# session where the sampleTidy PACKAGE HAS ALREADY BEEN LOADED VIA
# `devtools::load_all(".")` (Robin's ruling 4, Phase 7b round 3, 2026-07-26).
# REQUIRED, not merely convenient: the verify gate calls the INTERNAL functions
# `.rc_load_registry()`, `.rc_resolve_one_analyte()`, `.rc_lab_kind()` and
# `.rc_method_key()`, invisible to an unqualified lookup once this file is
# `sys.source()`d against a merely-INSTALLED package.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/006-acirl-transcription-methods.R", envir = env)
#   env$mig006_run(db = "/path/to/monitoring.duckdb",
#                  snapshot_dir = "/path/to/snapshots",
#                  mapping = "dev/migrations/006-acirl-transcription-methods.csv",
#                  dry_run = TRUE)
#
# INDEPENDENT OF 004 AND 005, and that is a decision rather than an oversight.
# 004/005 rebuild views; this writes registry rows. The five reporting views
# join `analysis`, and this migration creates no analyses, so every view's row
# count is unchanged whether or not they have been rebuilt. Requiring a 1005
# marker would be a false dependency that blocks this pass if Robin chooses not
# to apply 005.
#
# The verify gate has the same TWO halves 004 established.
# `mig006_verify()` proves the SAFETY property (every base table this migration
# must not touch is byte-identical, `analysis` above all). `.mig006_verify_methods()`
# proves the SUCCESS property - and it proves it THROUGH THE PRODUCTION RESOLVER
# rather than by re-reading the rows it just inserted. Asking
# `.rc_resolve_one_analyte(label, "ACIRL", NA, registry)` is the only question
# that actually matters, it is answered by the same code the import will run,
# and it shares no mechanism with the INSERT - so the two cannot be wrong
# together in the same way.

.mig006_marker_version <- 1006L

.mig006_actor <- "006-acirl-transcription-methods"

.mig006_reason <- paste(
  "A79 step 6a: ACIRL transcription label linked to its analyte so the",
  "transcription import resolves rather than dangling"
)

#' The organisation every row this migration writes belongs to
.mig006_org <- "ACIRL"

#' The mapping columns required of the CSV / data frame
.mig006_required_cols <- c("label", "analyte", "uuid_analyte")

.mig006_default <- function(x, default) if (is.null(x)) default else x

#' Guard: the internal reconcile helpers this migration verifies through
#'
#' Fails in the CALLER's session, before the backup is taken, if the package
#' was not loaded with `devtools::load_all(".")`. Same shape as 005's
#' `.mig005_field_methods()` guard and for the same reason - a stray backup
#' copy must not be left behind by a run that could never have succeeded.
#'
#' @return invisible(TRUE); throws `sampletidy_error` otherwise.
.mig006_require_internals <- function() {
  needed <- c(".rc_load_registry", ".rc_resolve_one_analyte",
              ".rc_lab_kind", ".rc_method_key")
  missing <- needed[!vapply(needed, exists, logical(1), mode = "function")]
  if (length(missing) > 0) {
    cli::cli_abort(
      "006-acirl-transcription-methods: {paste(missing, collapse = ', ')} (R/reconcile.R)
       {?is/are} not visible. This migration verifies its own success by asking the
       PRODUCTION resolver, so it must be run from a session where the package was
       loaded with {.code devtools::load_all(\".\")} - see the file header.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

# ---- the mapping --------------------------------------------------------

#' Read and structurally validate the label -> analyte mapping
#'
#' Accepts a path to a CSV or an already-built data frame. Every check here is
#' about the mapping ALONE - nothing that needs the database, which is
#' `.mig006_check_preconditions()`'s job.
#'
#' @param mapping path to a CSV, or a data.frame.
#' @return a data.frame with at least `label`, `analyte`, `uuid_analyte`.
.mig006_read_mapping <- function(mapping) {
  map <- if (is.data.frame(mapping)) {
    mapping
  } else {
    checkmate::assert_string(mapping)
    if (!file.exists(mapping)) {
      cli::cli_abort(
        "006-acirl-transcription-methods: mapping file not found: {mapping}.",
        class = "sampletidy_error"
      )
    }
    utils::read.csv(mapping, stringsAsFactors = FALSE, encoding = "UTF-8",
                    colClasses = "character")
  }

  missing_cols <- setdiff(.mig006_required_cols, names(map))
  if (length(missing_cols) > 0) {
    cli::cli_abort(
      "006-acirl-transcription-methods: mapping is missing required column(s)
       {paste(missing_cols, collapse = ', ')}.",
      class = "sampletidy_error"
    )
  }

  # NON-VACUITY. An empty mapping would sail through every check below and
  # write nothing, and a migration that reports success for doing nothing is
  # indistinguishable from one whose mapping failed to load.
  if (nrow(map) == 0) {
    cli::cli_abort(
      "006-acirl-transcription-methods: the mapping is EMPTY. There is nothing to
       link, so the run is refused rather than reported as a success.",
      class = "sampletidy_error"
    )
  }

  for (col in .mig006_required_cols) {
    v <- map[[col]]
    if (any(is.na(v) | !nzchar(trimws(v)))) {
      bad <- which(is.na(v) | !nzchar(trimws(v)))
      cli::cli_abort(
        "006-acirl-transcription-methods: mapping column `{col}` is blank on
         row(s) {paste(utils::head(bad, 5), collapse = ', ')}.",
        class = "sampletidy_error"
      )
    }
  }

  # The label is matched byte-for-byte by the resolver's exact branch, so a
  # label with surrounding whitespace would mint a method the import can never
  # hit on that branch. Refuse rather than silently trim - trimming would make
  # the stored name differ from the reviewed mapping.
  ws <- map$label != trimws(map$label)
  if (any(ws)) {
    cli::cli_abort(
      "006-acirl-transcription-methods: {sum(ws)} label(s) carry leading or
       trailing whitespace (e.g. {sQuote(map$label[which(ws)[[1]]])}). The
       resolver's exact branch is a byte-for-byte name match, so these would
       mint methods the import cannot hit. Fix the mapping, do not trim here.",
      class = "sampletidy_error"
    )
  }

  dup <- duplicated(map$label)
  if (any(dup)) {
    cli::cli_abort(
      "006-acirl-transcription-methods: duplicate label(s) in the mapping:
       {paste(unique(map$label[dup]), collapse = ', ')}.",
      class = "sampletidy_error"
    )
  }

  # Two labels that FOLD to one key each mint their own method, and
  # `.rc_lab_method_candidates()` then returns BOTH for either label.
  #
  # THAT IS ONLY A DEFECT IF THEY DISAGREE ABOUT THE ANALYTE, and this gate is
  # written to the real failure mode rather than to the tempting stricter one.
  # `.rc_resolve_one_analyte()` returns `ambiguous` only when the folded
  # survivors span MORE THAN ONE distinct analyte (R/reconcile.R:1309-1317);
  # when they agree it resolves, deterministically, to the uuid-sorted first.
  # The live corpus has exactly one such pair - `Azinphos Methyl` (99 rows) and
  # `Azinphos-methyl` (1), both the same analyte - and the stricter gate would
  # have dropped a real label for a danger that is not there.
  keys <- .rc_method_key(map$label)
  if (any(is.na(keys))) {
    bad <- map$label[is.na(keys)]
    cli::cli_abort(
      "006-acirl-transcription-methods: label(s) {paste(sQuote(bad), collapse = ', ')}
       fold to nothing (blank or punctuation-only), so no method key can be hung
       on them (the A44/F.1 rule).",
      class = "sampletidy_error"
    )
  }
  shared <- unique(keys[duplicated(keys)])
  split_keys <- shared[vapply(
    shared,
    function(k) length(unique(map$uuid_analyte[keys == k])) > 1,
    logical(1)
  )]
  if (length(split_keys) > 0) {
    bad <- map$label[keys %in% split_keys]
    cli::cli_abort(
      "006-acirl-transcription-methods: label(s) {paste(sQuote(bad), collapse = ', ')}
       fold to the same method key but map to DIFFERENT analytes, which makes
       every one of them `ambiguous` at import instead of resolving any.",
      class = "sampletidy_error"
    )
  }

  map
}

#' Everything that needs the database: analytes exist and are named what the
#' mapping says, no ACIRL method already claims the label, and every label is
#' genuinely unresolved TODAY.
#'
#' @param con an open DBI connection.
#' @param map a validated mapping.
#' @return invisible(TRUE); throws `sampletidy_error` otherwise.
.mig006_check_preconditions <- function(con, map) {
  analyte <- DBI::dbGetQuery(con, "SELECT uuid, name FROM analyte")

  unknown <- setdiff(map$uuid_analyte, analyte$uuid)
  if (length(unknown) > 0) {
    cli::cli_abort(
      "006-acirl-transcription-methods: {length(unknown)} mapped analyte uuid(s)
       do not exist in `analyte` (e.g. {paste(utils::head(unknown, 3), collapse = ', ')}).
       This migration links to existing analytes only - create any new one with
       add_analyte() first.",
      class = "sampletidy_error"
    )
  }

  # The `analyte` NAME column is redundant with `uuid_analyte` BY DESIGN. It is
  # what makes the mapping reviewable by a human, and checking the two against
  # each other catches the one edit that is otherwise undetectable: a
  # hand-edited CSV whose name and uuid have drifted apart, which would link a
  # label to an analyte nobody reviewed.
  want <- analyte$name[match(map$uuid_analyte, analyte$uuid)]
  drift <- want != map$analyte
  if (any(drift)) {
    i <- which(drift)[[1]]
    cli::cli_abort(
      "006-acirl-transcription-methods: {sum(drift)} mapping row(s) name an analyte
       that is not what the uuid points at - e.g. label {sQuote(map$label[i])} says
       {sQuote(map$analyte[i])} but {map$uuid_analyte[i]} is {sQuote(want[i])}.
       The name column exists so a human can review the mapping; a disagreement
       means the file was edited without re-deriving it.",
      class = "sampletidy_error"
    )
  }

  # Bound to a local because cli treats a `{}` expression STARTING WITH A DOT
  # as a style name, not a value (cli >= 3.4.0). `{.mig006_org}` in the abort
  # below aborted with an `rlib_error` about an invalid cli literal instead of
  # the `sampletidy_error` this gate promises - and the tests only caught it
  # once the preconditions moved out from under a wrapper that had been
  # re-classing it. A broken error message is a broken gate.
  org <- .mig006_org
  lm <- DBI::dbGetQuery(
    con, "SELECT uuid, name, method, uuid_analyte FROM lab_method WHERE organisation = ?",
    params = list(org)
  )
  if (nrow(lm) > 0) {
    lm_keys <- .rc_method_key(lm$name)
    hit <- .rc_method_key(map$label) %in% lm_keys[!is.na(lm_keys)]
    if (any(hit)) {
      i <- which(hit)[[1]]
      cli::cli_abort(
        "006-acirl-transcription-methods: {sum(hit)} label(s) already match an
         existing {org} lab_method by folded key - e.g. {sQuote(map$label[i])}.
         Minting a second method for the same key would make the label AMBIGUOUS
         at import (two candidates, possibly two analytes) instead of resolving
         it. Remove these from the mapping, or confirm the existing method with
         confirm_analyte_methods() instead.",
        class = "sampletidy_error"
      )
    }
  }

  # THERE IS DELIBERATELY NO SEPARATE "this label already resolves" GATE, and
  # the reason is worth recording because writing one is the obvious next move.
  # It would be UNREACHABLE. `.rc_resolve_one_analyte()` can only return
  # `resolved` for organisation ACIRL via its exact branch (name equality AND
  # org) or its folded branch (folded-key equality AND org) - and both require
  # an ACIRL `lab_method` whose folded key equals the label's, which is exactly
  # what the collision gate above already refuses. "Already resolved" is a
  # strict subset of "already collides" (the collision gate additionally
  # catches a DANGLING ACIRL method, which resolves to `dangling_method`, not
  # `resolved`). A gate whose failing case cannot be reached passes vacuously
  # and reads as protection that is not there.
  invisible(TRUE)
}

# ---- the write ----------------------------------------------------------

#' The `lab_method` rows this migration appends
#'
#' Split out from the write so the tests can assert the SHAPE without a
#' database, and so a mutation to it is visible in one place.
#'
#' @param map a validated mapping.
#' @param uuids character vector of row uuids, same length as `nrow(map)`.
#' @return a data.frame ready for `db_append()`.
.mig006_rows <- function(map, uuids) {
  data.frame(
    uuid = uuids,
    uuid_analyte = map$uuid_analyte,
    name = map$label,
    method = NA_character_,          # header note (a) - the transcription marker
    organisation = .mig006_org,
    rl_low = NA_real_,
    rl_high = NA_real_,
    units = NA_character_,           # header note (b) - deliberately not the corpus units
    conversion_constant = NA_real_,
    stringsAsFactors = FALSE
  )
}

#' Append the mapped methods through the MUTATION LAYER (002's rule: never a
#' raw dbExecute), so every row lands in `change_log` as an insert.
#'
#' @param con an open DBI connection inside the migration's transaction.
#' @param map a validated mapping.
#' @param uuid_fn a nullary uuid generator (injectable for tests).
#' @return the appended data frame, invisibly.
.mig006_append_methods <- function(con, map, uuid_fn = uuid::UUIDgenerate) {
  uuids <- vapply(seq_len(nrow(map)), function(i) uuid_fn(), character(1))
  rows <- .mig006_rows(map, uuids)
  db_append(con, "lab_method", rows, actor = .mig006_actor, reason = .mig006_reason)
  invisible(rows)
}

# ---- verify: the SAFETY half --------------------------------------------

#' Row counts + a value checksum over every base table this migration must not
#' change. `lab_method` is excluded (it is the one table that grows) and so are
#' the append-only ops tables.
#'
#' @param con an open DBI connection.
#' @return a named list.
mig006_counts_checksum <- function(con) {
  tbls <- c("feature", "feature_mask", "analyte", "sample", "analysis")
  present <- DBI::dbListTables(con)
  out <- list()
  for (t in tbls) {
    if (!(t %in% present)) {
      out[[t]] <- NA_integer_
      next
    }
    out[[t]] <- as.integer(DBI::dbGetQuery(con, sprintf("SELECT COUNT(*) n FROM %s", t))$n)
  }
  if ("feature_alias" %in% present) {
    out$feature_alias <- as.integer(
      DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_alias")$n)
  }
  # `analysis` is the table an error here would damage most, so it gets a
  # CONTENT checksum, not merely a count: a migration that swapped two values
  # without changing the row count would pass a count-only gate.
  out$analysis_checksum <- if ("analysis" %in% present) {
    as.character(DBI::dbGetQuery(
      con,
      "SELECT COALESCE(SUM(HASH(COALESCE(uuid, '') || '|' || COALESCE(uuid_sample, '')
         || '|' || COALESCE(uuid_lab, '') || '|' || COALESCE(CAST(value AS VARCHAR), ''))), 0) h
       FROM analysis"
    )$h)
  } else {
    NA_character_
  }
  out
}

#' The SAFETY half: nothing this migration must not touch has moved.
#'
#' @param before,after `mig006_counts_checksum()`-shaped lists.
#' @return invisible(TRUE); throws otherwise.
mig006_verify <- function(before, after) {
  if (!identical(names(before), names(after))) {
    cli::cli_abort(
      "006-acirl-transcription-methods verify failed: the before/after count
       structures differ.",
      class = "sampletidy_error"
    )
  }
  bad <- names(before)[!vapply(
    names(before), function(n) identical(before[[n]], after[[n]]), logical(1))]
  if (length(bad) > 0) {
    cli::cli_abort(
      "006-acirl-transcription-methods verify failed: this migration writes
       `lab_method` and nothing else, but {paste(bad, collapse = ', ')} changed.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

# ---- verify: the SUCCESS half -------------------------------------------

#' The SUCCESS half, asked through the PRODUCTION resolver
#'
#' Deliberately NOT a re-read of the rows just inserted. The property that
#' matters is not "did the INSERT store what I passed it" - it is "will the
#' import now resolve this label to this analyte, and classify it as a
#' transcription". Those are answered by `.rc_resolve_one_analyte()` and
#' `.rc_lab_kind()`, the same functions the import runs, sharing no mechanism
#' with the INSERT.
#'
#' @param con an open DBI connection inside the migration's transaction.
#' @param map a validated mapping.
#' @param n_before `lab_method` row count before the append.
#' @return invisible(TRUE); throws otherwise.
.mig006_verify_methods <- function(con, map, n_before) {
  n_after <- as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n)
  if (!identical(n_after, n_before + nrow(map))) {
    cli::cli_abort(
      "006-acirl-transcription-methods verify failed: expected `lab_method` to grow
       by exactly {nrow(map)} rows ({n_before} -> {n_before + nrow(map)}), got {n_after}.",
      class = "sampletidy_error"
    )
  }

  registry <- .rc_load_registry(con)

  bad_resolve <- character(0)
  bad_kind <- character(0)
  for (i in seq_len(nrow(map))) {
    lb <- map$label[[i]]
    res <- .rc_resolve_one_analyte(lb, .mig006_org, NA_character_, registry)
    if (!identical(res$status, "resolved") ||
        !identical(res$uuid_analyte, map$uuid_analyte[[i]])) {
      bad_resolve <- c(bad_resolve, sprintf(
        "%s (status %s, analyte %s, wanted %s)",
        lb, res$status, res$uuid_analyte, map$uuid_analyte[[i]]))
      next
    }
    # A resolved method that classifies as anything but `acirl_transcription`
    # is exempt from A79 supersession forever - the exact failure this
    # migration exists to prevent, so it is checked, not assumed.
    kind <- .rc_lab_kind(res$uuid_lab, registry)
    if (!identical(kind, "acirl_transcription")) {
      bad_kind <- c(bad_kind, sprintf("%s (kind %s)", lb, kind))
    }
  }

  if (length(bad_resolve) > 0) {
    cli::cli_abort(
      "006-acirl-transcription-methods verify failed: {length(bad_resolve)} of
       {nrow(map)} label(s) do not resolve to their mapped analyte through the
       production resolver - e.g. {paste(utils::head(bad_resolve, 3), collapse = '; ')}.",
      class = "sampletidy_error"
    )
  }
  if (length(bad_kind) > 0) {
    cli::cli_abort(
      "006-acirl-transcription-methods verify failed: {length(bad_kind)} minted
       method(s) do not classify as `acirl_transcription`, so A79 supersession
       could never reach them - e.g. {paste(utils::head(bad_kind, 3), collapse = '; ')}.",
      class = "sampletidy_error"
    )
  }

  invisible(TRUE)
}

# ---- backup -------------------------------------------------------------

.mig006_backup_counts <- function(con) {
  list(
    analyte = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analyte")$n),
    lab_method = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n),
    analysis = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n)
  )
}

#' Copy `db` to `snapshot_dir` and verify the copy opens and matches.
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory for the backup.
#' @param .now inject a POSIXct instead of `Sys.time()`.
#' @return the backup path.
mig006_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig006_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  fname <- sprintf("monitoring_pre-006-acirl-transcription-methods_%sZ.duckdb", ts)
  dest <- file.path(snapshot_dir, fname)

  live_counts <- with_db_write(
    function(con) {
      DBI::dbExecute(con, "CHECKPOINT")
      counts <- .mig006_backup_counts(con)
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

  backup_counts <- .mig006_backup_counts(verify_con)
  if (!identical(live_counts, backup_counts)) {
    cli::cli_abort(
      "{db}: backup verification failed - row counts differ between live DB and {dest}.",
      class = "sampletidy_error"
    )
  }

  dest
}

# ---- mig006_run() -------------------------------------------------------

#' Run (or dry-run) the 006-acirl-transcription-methods migration
#'
#' Never invoked by package code (A50).
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory for the pre-migration backup.
#' @param mapping path to the mapping CSV, or a data frame.
#' @param dry_run if `TRUE`, report what would happen and write nothing.
#' @param .now inject a POSIXct instead of `Sys.time()`.
#' @param .uuid_fn inject a uuid generator (tests only).
#' @return invisible list(status, backup_path, restore_command, n_methods,
#'   counts_before, counts_after, recorded_at).
mig006_run <- function(db, snapshot_dir, mapping, dry_run = FALSE,
                       .now = NULL, .uuid_fn = uuid::UUIDgenerate) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  # Fail FAST, in the caller's session, before the backup is taken.
  .mig006_require_internals()
  map <- .mig006_read_mapping(mapping)

  # ---- Step 0: idempotency marker ----
  marker_con <- st_connect(db, read_only = TRUE)
  if (!("schema_version" %in% DBI::dbListTables(marker_con))) {
    DBI::dbDisconnect(marker_con, shutdown = TRUE)
    cli::cli_abort(
      "{db}: no schema_version table found - ensure_schema() has never been
       applied to this database, so 006-acirl-transcription-methods cannot check
       its own idempotency marker.",
      class = "sampletidy_error"
    )
  }
  marker <- tryCatch(
    DBI::dbGetQuery(
      marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
      params = list(.mig006_marker_version)
    ),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE)
  )

  if (nrow(marker) > 0) {
    recorded_at <- marker$applied_at[[1]]
    logf("006-acirl-transcription-methods already applied at %s; nothing to do.",
         format(recorded_at))
    read_con <- st_connect(db, read_only = TRUE)
    counts <- tryCatch(
      mig006_counts_checksum(read_con),
      finally = DBI::dbDisconnect(read_con, shutdown = TRUE)
    )
    return(invisible(list(
      status = "already_migrated",
      backup_path = NA_character_,
      restore_command = NA_character_,
      n_methods = 0L,
      counts_before = counts,
      counts_after = counts,
      recorded_at = recorded_at
    )))
  }

  # ---- dry run: every gate, no write, no backup ----
  if (isTRUE(dry_run)) {
    preview_con <- st_connect(db, read_only = TRUE)
    counts_before <- tryCatch({
      .mig006_check_preconditions(preview_con, map)
      mig006_counts_checksum(preview_con)
    }, finally = DBI::dbDisconnect(preview_con, shutdown = TRUE))
    logf("DRY RUN: would mint %d %s lab_method row(s), method NULL, units NULL.",
         nrow(map), .mig006_org)
    logf("DRY RUN: all %d label(s) are unresolved today and every mapped analyte exists.",
         nrow(map))
    logf("DRY RUN: no backup taken, no writes made to %s.", db)
    return(invisible(list(
      status = "dry_run",
      backup_path = NA_character_,
      restore_command = NA_character_,
      n_methods = nrow(map),
      counts_before = counts_before,
      counts_after = NA,
      recorded_at = NA
    )))
  }

  # ---- Step 1: every precondition, on a READ-ONLY connection, BEFORE the
  # backup. 005's rule: a run that could never have succeeded must not leave a
  # stray backup copy behind. They are re-checked inside the transaction below,
  # because the database can move between these two moments. ----
  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(
    .mig006_check_preconditions(pre_con, map),
    finally = DBI::dbDisconnect(pre_con, shutdown = TRUE)
  )

  # ---- Step 2: back up and verify, before any write ----
  backup_path <- mig006_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)

  recorded_at <- .mig006_default(.now, Sys.time())

  result <- with_db_write(
    function(con) {
      counts_before <- mig006_counts_checksum(con)

      body <- db_transaction(con, function(con) {
        # Re-checked INSIDE the transaction, not only in the dry run: the
        # database may have moved between a dry run and the real one.
        .mig006_check_preconditions(con, map)

        n_before <- as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n)
        .mig006_append_methods(con, map, uuid_fn = .uuid_fn)

        DBI::dbExecute(
          con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
          params = list(.mig006_marker_version, recorded_at)
        )

        counts_after <- mig006_counts_checksum(con)
        mig006_verify(counts_before, counts_after)
        .mig006_verify_methods(con, map, n_before)

        list(counts_after = counts_after)
      })

      logf("Verify passed: %d label(s) now resolve to their analyte as `acirl_transcription`.",
           nrow(map))

      list(counts_before = counts_before, counts_after = body$counts_after)
    },
    db = db
  )

  logf("006-acirl-transcription-methods migrated successfully.")

  invisible(list(
    status = "migrated",
    backup_path = backup_path,
    restore_command = restore_command,
    n_methods = nrow(map),
    counts_before = result$counts_before,
    counts_after = result$counts_after,
    recorded_at = recorded_at
  ))
}
