# Operator-run migration: give four Aroclor MIXTURES their own names and CAS.
#
# NOT ONE NUMBER CHANGES. This migration writes `analyte.name`, `analyte.CAS`
# and the matching `analyte_mask` display name, and nothing else. `analysis`,
# `lab_method`, `sample` and `feature` are proved byte-identical end to end by
# the safety half of `mig010_verify()`, and every analyte column other than
# `name`/`CAS` on the four target rows is frozen by the same checksum.
#
# ---- THE DEFECT ----
#
# An Aroclor is a commercial PCB MIXTURE, not a congener. ALS analyses the
# mixture - its own method heading says so verbatim,
# `EP131B: Polychlorinated Biphenyls (as Aroclors)`, i.e. USEPA 8082A
# quantification by pattern recognition against Aroclor technical standards -
# and prints the CORRECT mixture CAS on its COAs and ENMRG exports.
#
# Our registry does not. Four analytes carry a CONGENER's name and a CONGENER's
# CAS. The mechanism (evidence: `scratchpad/a90_aroclor_cas.md`): PubChem
# Compound records are STRUCTURE-keyed, a mixture has no single structure, so
# PubChem merges each Aroclor into the record of the one congener whose chlorine
# weight-% matches - and a legacy CAS-keyed lookup through that merged record
# read back the congener's preferred name and preferred CAS. Four for four, the
# congener we hold is exactly PubChem's merge partner. That is a fingerprint,
# not a coincidence.
#
# The four wrong rows are also chemically impossible as reported: none of
# PCB 36, 80, 82 or 128 appears in method 8082A's congener list, so no routine
# environmental method reports them at all. Any report, EPA return or guideline
# comparison printing those names is printing a substance that was never
# measured. All the affected values are non-detects at ALS's LOR, so no NUMBER
# is wrong - but the labels are not defensible if published, which is why this
# is worth a migration rather than a note.
#
# Robin's ruling, 2026-08-08: rename them to the mixture, with ALS's (and the
# EPA's, and ATSDR's) CAS.
#
#   3,3',5-Trichlorobiphenyl          38444-87-0  ->  Aroclor 1016  12674-11-2
#   3,3',5,5'-Tetrachlorobiphenyl     33284-52-5  ->  Aroclor 1248  12672-29-6
#   2,2',3,3',4-Pentachlorobiphenyl   52663-62-4  ->  Aroclor 1254  11097-69-1
#   2,2',3,3',4,4'-Hexachlorobiphenyl 38380-07-3  ->  Aroclor 1260  11096-82-5
#
# EXPLICITLY OUT OF SCOPE, all three already correct: `Aroclor 1221`
# (11104-28-2), `Aroclor 1232` (11141-16-5), and `Chlorodiphenyl` (53469-21-9),
# which is Aroclor 1242 under its archaic OSHA trade name - right substance,
# old name, so a rename there would be cosmetic and is not ruled.
#
# ---- WHY `analyte_mask` IS IN SCOPE, THOUGH THE RULING'S TABLE DOES NOT NAME IT ----
#
# The analyte's name is stored TWICE. `v_analyte_long` and `v_measurement_long`
# read `COALESCE(analyte_mask.name, analyte.name)`, and all four target analytes
# carry a `long`-variant mask row holding the lower-cased CONGENER name:
#
#   938f0eae... long  "3,3',5-trichlorobiphenyl"
#   0eee4bc2... long  "3,3',5,5'-tetrachlorobiphenyl"
#   e8b555a3... long  "2,2',3,3',4-pentachlorobiphenyl"
#   34443be4... long  "2,2',3,3',4,4'-hexachlorobiphenyl"
#
# Renaming only `analyte` would leave the database CONTRADICTING ITSELF - the
# registry saying `Aroclor 1254`, the long-form reporting view still printing
# the congener - and the long views are precisely where a published report gets
# its analyte name from. That is the exact harm the ruling exists to stop, so
# this is the SAME rename applied to the other place the same name lives, not a
# second ruling. It is listed declaratively below and is one line to drop if
# Robin disagrees.
#
# The `EPA` variant rows for these four carry `name = NULL` (they exist only to
# set `conversion_constant = 1`), so `v_analyte_epa` already falls through to
# `analyte.name` and needs no change. Verified read-only before this was written.
#
# MEASURED CORRECTION to the justification above, made before this migration was
# ever applied: those 8 `analysis` rows do NOT currently reach
# `v_measurement_long` AT ALL - the view returns 0 rows for them - so the LIVE
# publication exposure ran through `v_measurement.analyte_name`, which the
# `analyte` rename fixes on its own. The mask rewrite is therefore correcting a
# WRONG STORED NAME rather than removing a name being printed today. It is still
# right, and `v_analyte_long` does print it; but the claim "the long view would
# still print the congener" overstated what is currently reachable, and a gate
# justified by an unreachable harm is how vacuous gates get written.
#
# ---- AND TWO MASKS NAMING AN AROCLOR THAT DOES NOT EXIST (ruled 2026-08-09) ----
#
# Surfaced while building the four renames, ruled separately, and folded in here
# because 010 had not yet been applied to any database:
#
#   fda36258... long  "Aroclor 1222"   on analyte `Aroclor 1221`
#   bb4f58ec... long  "Aroclor 1233"   on analyte `Aroclor 1232`
#
# The commercial Aroclor series is 1016, 1221, 1232, 1242, 1248, 1254 and 1260.
# There is no 1222 and no 1233, so unlike the four renames - where the stored
# name was at least a real compound - these two print a substance that has never
# existed. Both analytes are otherwise CORRECT (`11104-28-2` and `11141-16-5`,
# matching ALS and the authorities), so this is a DISPLAY-NAME-ONLY fix, and its
# preconditions and its verify both pin `analyte.name` and `analyte.CAS` as
# things that must NOT move - the mirror image of what the renames assert. A fix
# that "corrected" the display name by renaming the analyte underneath it would
# pass a naive check perfectly.
#
# ---- WHAT IS DELIBERATELY LEFT ALONE ----
#
# `analyte.comments` still reads "Sold as Aroclor 1260", "Major constiuient of
# commercial Aroclor 1016 PCB mixture" (sic) and so on. Left as they are ON
# PURPOSE: after the rename they are tautological rather than false, they are
# free text no view or resolver consumes, and together with the `change_log`
# rows this migration writes they are the only in-database record that these
# rows were once filed as congeners. The safety checksum PINS them unchanged.
#
# `lab_method.name` is ALS's own label (`Aroclor 1016`) and is already correct;
# nothing in `lab_method` moves. The analyte NAME is not a resolution key -
# `.rc_resolve_one_analyte()` matches on lab_method name/method, and touches
# `analyte` only for the CAS SUGGESTION path (R/reconcile.R, CONTRACT A66) - so
# no label's resolution changes. The success gate proves that through the
# production resolver rather than asserting it.
#
# ---- BLAST RADIUS, MEASURED ----
#
# 8 committed `analysis` rows (2 per analyte, all on the ALS `EP131B` methods),
# every one a non-detect: `value = rl_low = 1e-04` mg/L, `quantified = FALSE`,
# i.e. ALS's `<0.10 ug/L`. Plus 4 live ACIRL corpus rows. Each of the four
# analytes is reached by exactly TWO lab_methods - the pre-existing ALS one
# (2 analyses each) and the ACIRL transcription method migration 006 minted
# (0 analyses each). No `guideline` row references any of them, and
# `change_log` holds nothing for them (they predate the local-DB cutover).
#
# ---- RELATIONSHIP TO 006 ----
#
# `006-acirl-transcription-methods.csv` is updated alongside this file so its
# `analyte` column names the new analytes. That is SAFE for an already-applied
# 006: its `already_migrated` branch re-verifies by resolving each label through
# `.rc_resolve_one_analyte()` and comparing `res$uuid_analyte` against the CSV's
# `uuid_analyte` - it never reads the CSV's `analyte` NAME column. The uuids are
# unchanged by this migration, so a 006 re-run still reports `already_migrated`.
#
# The name column IS read by `.mig006_check_preconditions()`, which refuses when
# the CSV name and the database name for a uuid have drifted apart. That branch
# only runs on a database WITHOUT the 1006 marker - so the consequence is an
# ordering constraint on a rebuild from an unmigrated database: 010 must run
# BEFORE 006, exactly as 005 and 007 already must. 006's header already
# documents that its numeric position is not its run order.
#
# ---- MARKERS ----
# 1010. The live database carries 1..7, 1001, 1003..1009; this migration depends
# on none of them for its writes, but 1006 is checked as a warning-free FYI
# in the log line rather than a gate - see step 0.
#
# NEVER invoked by package code (A50). Run it from a session where the package
# was loaded with `devtools::load_all(".")` - the success gate calls the
# internal `.rc_load_registry()` / `.rc_resolve_one_analyte()`.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/010-aroclor-mixture-names.R", envir = env)
#   env$mig010_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig010_marker_version <- 1010L
.mig010_actor <- "010-aroclor-mixture-names"

.mig010_default <- function(x, default) if (is.null(x)) default else x

# ---- the rulings, declaratively ---------------------------------------------
#
# THE `uuid` IS PINNED, AND THAT IS DELIBERATE - it is the opposite of 007's
# rule for LOOKUPS, and for the opposite reason. 007 forbids uuid lookups
# because a natural key is reviewable and a uuid is not. Here the natural key IS
# THE THING BEING CHANGED: keying on `name` would mean this migration silently
# does nothing on a database where someone already half-renamed a row, and would
# key ruling and target to the same mutable string. So the uuid identifies the
# row, and BOTH the old name and the old CAS are checked before either is
# overwritten - which is strictly more evidence than a name lookup could give.
# The uuids are the ones measured read-only in `scratchpad/a90_aroclor_cas.md`.
.mig010_renames <- list(
  list(uuid      = "938f0eae-2f1f-4bf0-bcfb-b0063c3bef46",
       from_name = "3,3',5-Trichlorobiphenyl",
       to_name   = "Aroclor 1016",
       from_CAS  = "38444-87-0",
       to_CAS    = "12674-11-2",
       from_long = "3,3',5-trichlorobiphenyl",
       to_long   = "Aroclor 1016"),
  list(uuid      = "0eee4bc2-4508-42fa-b7f8-da1f1991bbd1",
       from_name = "3,3',5,5'-Tetrachlorobiphenyl",
       to_name   = "Aroclor 1248",
       from_CAS  = "33284-52-5",
       to_CAS    = "12672-29-6",
       from_long = "3,3',5,5'-tetrachlorobiphenyl",
       to_long   = "Aroclor 1248"),
  list(uuid      = "e8b555a3-c28a-480d-9b13-006bc46cf63f",
       from_name = "2,2',3,3',4-Pentachlorobiphenyl",
       to_name   = "Aroclor 1254",
       from_CAS  = "52663-62-4",
       to_CAS    = "11097-69-1",
       from_long = "2,2',3,3',4-pentachlorobiphenyl",
       to_long   = "Aroclor 1254"),
  list(uuid      = "34443be4-215a-443e-af4c-a2bb15031495",
       from_name = "2,2',3,3',4,4'-Hexachlorobiphenyl",
       to_name   = "Aroclor 1260",
       from_CAS  = "38380-07-3",
       to_CAS    = "11096-82-5",
       from_long = "2,2',3,3',4,4'-hexachlorobiphenyl",
       to_long   = "Aroclor 1260")
)

#' Two more `long` masks that name an Aroclor THAT DOES NOT EXIST.
#'
#' Robin ruled 2026-08-09, after the four renames above were already built:
#' `Aroclor 1221`'s long mask reads `Aroclor 1222` and `Aroclor 1232`'s reads
#' `Aroclor 1233`. Neither is a real Aroclor - the commercial series runs 1016,
#' 1221, 1232, 1242, 1248, 1254, 1260 - so both masks print a substance that has
#' never existed, which is a worse failure than the congener names: a congener at
#' least IS a real compound.
#'
#' These two analytes are otherwise CORRECT and are not renamed. `Aroclor 1221`
#' carries CAS `11104-28-2` and `Aroclor 1232` carries `11141-16-5`, both
#' verified against the authorities during the a90 investigation and both
#' matching what ALS prints. So this is a mask-only correction, and the
#' preconditions below pin `analyte.name` and `analyte.CAS` as things that must
#' NOT move - the opposite of what `.mig010_renames` asks.
.mig010_mask_fixes <- list(
  list(uuid         = "fda36258-7c29-4d1d-953a-597f14667c42",
       analyte_name = "Aroclor 1221",
       analyte_CAS  = "11104-28-2",
       from_long    = "Aroclor 1222",
       to_long      = "Aroclor 1221"),
  list(uuid         = "bb4f58ec-7d96-4c72-b0ca-8f617c6267d9",
       analyte_name = "Aroclor 1232",
       analyte_CAS  = "11141-16-5",
       from_long    = "Aroclor 1233",
       to_long      = "Aroclor 1232")
)

#' The `long` mask variant is the one `v_analyte_long` / `v_measurement_long`
#' COALESCE over `analyte.name`.
.mig010_mask_variant <- "long"

#' Every analyte uuid whose `long` mask name this migration may change.
#'
#' The union of the four renames and the two mask-only fixes. The `analyte`
#' checksum stays keyed on the FOUR - the two fixes must not move `analyte` at
#' all, and blanking their name/CAS would be exactly the hole that let it.
#' @keywords internal
.mig010_mask_keys <- function() {
  c(.mig010_field("uuid"),
    vapply(.mig010_mask_fixes, function(spec) spec$uuid, character(1)))
}

.mig010_field <- function(field) {
  vapply(.mig010_renames, function(spec) spec[[field]], character(1))
}

# ---- preconditions -----------------------------------------------------------

#' Every precondition, checkable read-only, so a doomed run leaves no backup.
#'
#' The shape of the check is "the registry is in EXACTLY the state the ruling
#' was made against" - old name AND old CAS AND old mask name, plus nothing
#' already sitting on the new name or the new CAS. A rename is not idempotent by
#' construction the way an INSERT is, so the starting state has to be pinned
#' from both ends.
#' @keywords internal
.mig010_check_preconditions <- function(con) {
  have_mask <- "analyte_mask" %in% DBI::dbListTables(con)
  if (!have_mask) {
    cli::cli_abort(
      "010-aroclor-mixture-names: table `analyte_mask` does not exist. This
       migration renames the `long`-variant display name alongside
       `analyte.name`, because `v_analyte_long` COALESCEs one over the other and
       renaming only half would leave the database contradicting itself.",
      class = "sampletidy_error"
    )
  }

  for (spec in .mig010_renames) {
    got <- DBI::dbGetQuery(con, "SELECT uuid, name, CAS FROM analyte WHERE uuid = ?",
                           params = list(spec$uuid))
    if (nrow(got) != 1L) {
      n_hit <- nrow(got)
      cli::cli_abort(
        "010-aroclor-mixture-names: analyte {spec$uuid} matches {n_hit} rows, not
         exactly 1. The ruling names a specific row; refusing rather than
         guessing which one it meant.",
        class = "sampletidy_error"
      )
    }
    if (!identical(got$name[[1]], spec$from_name)) {
      have <- got$name[[1]]
      cli::cli_abort(
        "010-aroclor-mixture-names: analyte {spec$uuid} is named {sQuote(have)},
         not {sQuote(spec$from_name)} as the ruling assumes. Refusing - the
         registry moved since the ruling was made.",
        class = "sampletidy_error"
      )
    }
    if (!identical(got$CAS[[1]], spec$from_CAS)) {
      have <- got$CAS[[1]]
      cli::cli_abort(
        "010-aroclor-mixture-names: analyte {sQuote(spec$from_name)} carries CAS
         {sQuote(have)}, not {sQuote(spec$from_CAS)} as the ruling assumes. The
         whole point of the ruling is that the CONGENER CAS is the wrong one, so
         a different value means something else has already edited this row.",
        class = "sampletidy_error"
      )
    }

    # Nothing may already hold the name or the CAS we are moving to. A duplicate
    # analyte name is not enforced by the schema, and a duplicate CAS would make
    # reconcile's CAS-suggestion path (A66) pick arbitrarily between two rows.
    clash_name <- DBI::dbGetQuery(
      con, "SELECT uuid FROM analyte WHERE name = ? AND uuid <> ?",
      params = list(spec$to_name, spec$uuid))$uuid
    if (length(clash_name) > 0) {
      other <- clash_name[[1]]
      cli::cli_abort(
        "010-aroclor-mixture-names: analyte {other} is already named
         {sQuote(spec$to_name)}, so this rename would create two analytes with
         one name. Work out which is the real one before re-running.",
        class = "sampletidy_error"
      )
    }
    clash_cas <- DBI::dbGetQuery(
      con, "SELECT uuid FROM analyte WHERE CAS = ? AND uuid <> ?",
      params = list(spec$to_CAS, spec$uuid))$uuid
    if (length(clash_cas) > 0) {
      other <- clash_cas[[1]]
      cli::cli_abort(
        "010-aroclor-mixture-names: analyte {other} already carries CAS
         {sQuote(spec$to_CAS)}. Two analytes on one CAS make reconcile's CAS
         suggestion pick arbitrarily between them.",
        class = "sampletidy_error"
      )
    }

    mask <- DBI::dbGetQuery(
      con, "SELECT name FROM analyte_mask WHERE uuid_analyte = ? AND variant = ?",
      params = list(spec$uuid, .mig010_mask_variant))
    if (nrow(mask) != 1L) {
      n_hit <- nrow(mask)
      # Bound to a plain local: cli reads a `{}` expression that STARTS WITH A
      # DOT as a style name, not a value, so `{.mig010_mask_variant}` aborts with
      # an rlib_error about an unknown cli literal instead of this gate's
      # `sampletidy_error`. Third file in this repo to spring that trap.
      variant <- .mig010_mask_variant
      cli::cli_abort(
        "010-aroclor-mixture-names: {sQuote(spec$from_name)} has {n_hit}
         {sQuote(variant)}-variant analyte_mask rows, not exactly 1.
         `v_analyte_long` COALESCEs that name over `analyte.name`, so this
         migration has to know exactly which row to rewrite.",
        class = "sampletidy_error"
      )
    }
    if (!identical(mask$name[[1]], spec$from_long)) {
      have <- mask$name[[1]]
      cli::cli_abort(
        "010-aroclor-mixture-names: the long-form display name for
         {sQuote(spec$from_name)} is {sQuote(have)}, not {sQuote(spec$from_long)}
         as the ruling assumes. Refusing - overwriting it blindly would clobber
         whatever someone else decided.",
        class = "sampletidy_error"
      )
    }
  }

  # The two MASK-ONLY fixes. The shape of the check is deliberately the mirror
  # image of the block above: `analyte.name` and `analyte.CAS` must be exactly
  # what the ruling saw and must NOT be candidates for change, because these two
  # analytes are already correct and only their display name is wrong.
  for (spec in .mig010_mask_fixes) {
    got <- DBI::dbGetQuery(con, "SELECT name, CAS FROM analyte WHERE uuid = ?",
                           params = list(spec$uuid))
    if (nrow(got) != 1L) {
      n_hit <- nrow(got)
      cli::cli_abort(
        "010-aroclor-mixture-names: analyte {spec$uuid} matches {n_hit} rows,
         not 1, so the mask-only fix for {sQuote(spec$analyte_name)} cannot be
         applied.",
        class = "sampletidy_error"
      )
    }
    if (!identical(got$name[[1]], spec$analyte_name)) {
      have <- got$name[[1]]
      cli::cli_abort(
        "010-aroclor-mixture-names: analyte {spec$uuid} is named {sQuote(have)},
         not {sQuote(spec$analyte_name)}. This fix corrects a display name on an
         analyte assumed to be already correct; refusing rather than rewriting a
         mask onto a row that is not the one the ruling was made about.",
        class = "sampletidy_error"
      )
    }
    if (!identical(got$CAS[[1]], spec$analyte_CAS)) {
      have <- got$CAS[[1]]
      cli::cli_abort(
        "010-aroclor-mixture-names: {sQuote(spec$analyte_name)} carries CAS
         {sQuote(have)}, not {sQuote(spec$analyte_CAS)}. The ruling was that this
         analyte is CORRECT and only its display name is wrong; a different CAS
         means that premise no longer holds.",
        class = "sampletidy_error"
      )
    }

    variant <- .mig010_mask_variant
    mask <- DBI::dbGetQuery(
      con, "SELECT name FROM analyte_mask WHERE uuid_analyte = ? AND variant = ?",
      params = list(spec$uuid, variant))
    if (nrow(mask) != 1L) {
      n_hit <- nrow(mask)
      cli::cli_abort(
        "010-aroclor-mixture-names: {sQuote(spec$analyte_name)} has {n_hit}
         {sQuote(variant)}-variant analyte_mask rows, not exactly 1.",
        class = "sampletidy_error"
      )
    }
    if (!identical(mask$name[[1]], spec$from_long)) {
      have <- mask$name[[1]]
      cli::cli_abort(
        "010-aroclor-mixture-names: the long-form display name for
         {sQuote(spec$analyte_name)} is {sQuote(have)}, not
         {sQuote(spec$from_long)} as the ruling assumes. Refusing - overwriting
         it blindly would clobber whatever someone else decided.",
        class = "sampletidy_error"
      )
    }
  }
  invisible(TRUE)
}

# ---- the safety checksum -----------------------------------------------------
#
# `dbListTables()` returns VIEWS as well as tables on this database (there are
# fourteen `v_*` reporting views), so a naive sweep over it would try to
# checksum a view whose definition joins the very rows this migration edits and
# report a spurious failure. The tables are therefore ENUMERATED.

#' SQL that reads a table with the columns this migration MAY change blanked out
#' on the rows it may change them on.
#'
#' Built from `dbListFields()` rather than a hard-coded column list so it works
#' against both the live `analyte` (10 columns) and the leaner test DDL, and so
#' a column added later is frozen automatically instead of silently escaping the
#' checksum.
#' @keywords internal
.mig010_frozen_sql <- function(con, table, key_col, keys, mask_cols, order_by,
                               extra_where = NULL) {
  cols <- DBI::dbListFields(con, table)
  missing <- setdiff(mask_cols, cols)
  if (length(missing) > 0) {
    bad <- paste(missing, collapse = ", ")
    cli::cli_abort(
      "010-aroclor-mixture-names: table `{table}` has no column(s) {bad}, so the
       safety checksum cannot be built.",
      class = "sampletidy_error"
    )
  }
  in_list <- paste(as.character(DBI::dbQuoteString(con, keys)), collapse = ", ")
  target <- sprintf("%s IN (%s)",
                    as.character(DBI::dbQuoteIdentifier(con, key_col)), in_list)
  if (!is.null(extra_where)) target <- sprintf("(%s AND %s)", target, extra_where)

  sel <- vapply(cols, function(cn) {
    q <- as.character(DBI::dbQuoteIdentifier(con, cn))
    if (cn %in% mask_cols) sprintf("CASE WHEN %s THEN NULL ELSE %s END AS %s", target, q, q) else q
  }, character(1))
  sprintf("SELECT %s FROM %s ORDER BY %s", paste(sel, collapse = ", "),
          as.character(DBI::dbQuoteIdentifier(con, table)), order_by)
}

#' Content of everything this migration must not change.
#'
#' `analyte` and `analyte_mask` ARE included, with only the four rows' `name` /
#' `CAS` (and the four `long` mask names) blanked. So the checksum proves not
#' just "analysis did not move" but "no OTHER analyte moved, and nothing else
#' about these four moved either" - including their units, type,
#' conversion_constant and comments.
#' @keywords internal
mig010_counts_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  uuids <- .mig010_field("uuid")
  list(
    n_analysis = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n),
    n_analyte = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analyte")$n),
    n_lab_method = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n),
    n_sample = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM \"sample\"")$n),
    n_feature = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature")$n),
    n_analyte_mask = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analyte_mask")$n),
    analysis = q("SELECT uuid, uuid_sample, uuid_lab, value, value_chr, quantified,
                         rl_low, rl_high, purpose, comments FROM analysis ORDER BY uuid"),
    lab_method = q("SELECT * FROM lab_method ORDER BY uuid"),
    sample = q("SELECT * FROM \"sample\" ORDER BY uuid"),
    feature = q("SELECT * FROM feature ORDER BY uuid"),
    analyte = q(.mig010_frozen_sql(con, "analyte", "uuid", uuids,
                                   mask_cols = c("name", "CAS"),
                                   order_by = "uuid")),
    analyte_mask = q(.mig010_frozen_sql(
      con, "analyte_mask", "uuid_analyte", .mig010_mask_keys(), mask_cols = "name",
      order_by = "uuid_analyte, variant",
      extra_where = sprintf(
        "variant = %s",
        as.character(DBI::dbQuoteString(con, .mig010_mask_variant)))))
  )
}

#' The SAFETY half: nothing outside the four names, four CAS values and six
#' long-form display names moved.
mig010_verify <- function(before, after) {
  keys <- union(names(before), names(after))
  bad <- keys[!vapply(keys, function(n) identical(before[[n]], after[[n]]), logical(1))]
  if (length(bad) > 0) {
    moved <- paste(bad, collapse = ", ")
    cli::cli_abort(
      "010-aroclor-mixture-names verify failed: this migration changes only four
       analyte names, four CAS values and six long-form display names, but
       {moved} moved.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

#' The SUCCESS half: every rename landed, on the right row, in both places.
#'
#' Split out from `mig010_run()` and exported into the migration's environment
#' on purpose: it is also what the `already_migrated` branch re-asks, and it is
#' unit-tested directly. An end-to-end test that reads `analyte.name` straight
#' out of the database is already failed by any mutation to the WRITE, so it can
#' never be the thing that proves this gate works.
#' @keywords internal
.mig010_verify_renames <- function(con) {
  fail <- function(...) cli::cli_abort(paste0("010-aroclor-mixture-names verify failed: ", ...),
                                       class = "sampletidy_error")

  for (spec in .mig010_renames) {
    got <- DBI::dbGetQuery(con, "SELECT name, CAS FROM analyte WHERE uuid = ?",
                           params = list(spec$uuid))
    if (nrow(got) != 1L) fail("analyte {spec$uuid} matches {nrow(got)} rows, not 1.")
    if (!identical(got$name[[1]], spec$to_name)) {
      have <- got$name[[1]]
      fail("analyte {spec$uuid} is named {sQuote(have)}, expected {sQuote(spec$to_name)}.")
    }
    # THE CAS IS HALF THE RULING, NOT A DETAIL. A rename that left the congener
    # CAS in place would keep the row claiming to be PCB 36 to every CAS-keyed
    # consumer, including reconcile's own suggestion path - i.e. it would fix the
    # label and leave the identifier lying.
    if (!identical(got$CAS[[1]], spec$to_CAS)) {
      have <- got$CAS[[1]]
      fail("analyte {sQuote(spec$to_name)} carries CAS {sQuote(have)}, expected
            {sQuote(spec$to_CAS)}.")
    }
    mask <- DBI::dbGetQuery(
      con, "SELECT name FROM analyte_mask WHERE uuid_analyte = ? AND variant = ?",
      params = list(spec$uuid, .mig010_mask_variant))
    if (nrow(mask) != 1L) fail("{sQuote(spec$to_name)} has {nrow(mask)} long mask rows, not 1.")
    if (!identical(mask$name[[1]], spec$to_long)) {
      have <- mask$name[[1]]
      fail("the long-form display name for {sQuote(spec$to_name)} is
            {sQuote(have)}, expected {sQuote(spec$to_long)} - `v_analyte_long`
            would still print the congener.")
    }
  }

  # The two MASK-ONLY fixes. Both halves are asserted: the mask landed, AND the
  # analyte it hangs off did NOT move. The second half is the one that matters -
  # a fix that "corrected" the display name by renaming the analyte underneath it
  # would satisfy the first half perfectly.
  for (spec in .mig010_mask_fixes) {
    got <- DBI::dbGetQuery(con, "SELECT name, CAS FROM analyte WHERE uuid = ?",
                           params = list(spec$uuid))
    if (nrow(got) != 1L) fail("analyte {spec$uuid} matches {nrow(got)} rows, not 1.")
    if (!identical(got$name[[1]], spec$analyte_name)) {
      have <- got$name[[1]]
      fail("analyte {spec$uuid} is named {sQuote(have)}, expected
            {sQuote(spec$analyte_name)} - a MASK-ONLY fix must not have moved it.")
    }
    if (!identical(got$CAS[[1]], spec$analyte_CAS)) {
      have <- got$CAS[[1]]
      fail("analyte {sQuote(spec$analyte_name)} carries CAS {sQuote(have)},
            expected {sQuote(spec$analyte_CAS)} - a MASK-ONLY fix must not have
            moved it.")
    }
    mask <- DBI::dbGetQuery(
      con, "SELECT name FROM analyte_mask WHERE uuid_analyte = ? AND variant = ?",
      params = list(spec$uuid, .mig010_mask_variant))
    if (nrow(mask) != 1L) {
      fail("{sQuote(spec$analyte_name)} has {nrow(mask)} long mask rows, not 1.")
    }
    if (!identical(mask$name[[1]], spec$to_long)) {
      have <- mask$name[[1]]
      fail("the long-form display name for {sQuote(spec$analyte_name)} is
            {sQuote(have)}, expected {sQuote(spec$to_long)} - `v_analyte_long`
            would still print {sQuote(spec$from_long)}, which is not a real
            Aroclor.")
    }
  }
  invisible(TRUE)
}

#' Asked through the PRODUCTION resolver: no label's resolution moved.
#'
#' The analyte name is not a resolution key, so this SHOULD be a no-op - and
#' that is exactly why it is checked. `.rc_resolve_one_analyte()` reaches
#' `analyte` on the CAS-suggestion path (A66), and this migration rewrites CAS
#' on four rows; a gate that only re-read the UPDATE could not see a label that
#' stopped resolving.
#'
#' @param before named character vector, label -> uuid_analyte, captured before
#'   the writes.
#' @keywords internal
.mig010_label_resolutions <- function(con) {
  registry <- .rc_load_registry(con)
  lm <- DBI::dbGetQuery(
    con,
    sprintf("SELECT name, organisation FROM lab_method WHERE uuid_analyte IN (%s)
               ORDER BY name, organisation",
            paste(as.character(DBI::dbQuoteString(con, .mig010_field("uuid"))),
                  collapse = ", ")))
  if (nrow(lm) == 0L) {
    cli::cli_abort(
      "010-aroclor-mixture-names: not one lab_method points at the four analytes
       being renamed. That cannot be right - each is reached by its ALS EP131B
       method - and a resolution check over an empty set would pass vacuously.",
      class = "sampletidy_error"
    )
  }
  out <- vapply(seq_len(nrow(lm)), function(i) {
    res <- .rc_resolve_one_analyte(lm$name[[i]], lm$organisation[[i]],
                                   NA_character_, registry)
    paste0(res$status, "|", .mig010_default(res$uuid_analyte, NA_character_))
  }, character(1))
  stats::setNames(out, paste(lm$organisation, lm$name, sep = "|"))
}

# ---- backup ------------------------------------------------------------------

.mig010_backup_counts <- function(con) {
  list(
    analyte = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analyte")$n),
    analyte_mask = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analyte_mask")$n),
    lab_method = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n),
    analysis = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n)
  )
}

mig010_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig010_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir,
                    sprintf("monitoring_pre-010-aroclor-mixture-names_%sZ.duckdb", ts))

  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig010_backup_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)),
                   error = function(e) FALSE)
    if (!isTRUE(ok)) {
      cli::cli_abort("{db}: failed to write backup copy to {dest}.",
                     class = "sampletidy_error")
    }
    counts
  }, db = db)

  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE),
                         error = function(e) NULL)
  if (is.null(verify_con)) {
    cli::cli_abort("{db}: backup verification failed - cannot open {dest}.",
                   class = "sampletidy_error")
  }
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig010_backup_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.",
                   class = "sampletidy_error")
  }
  dest
}

# ---- mig010_run() ------------------------------------------------------------

#' Run (or dry-run) the 010-aroclor-mixture-names migration
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory for the pre-migration backup.
#' @param dry_run if `TRUE`, check every precondition and write nothing.
#' @param .now inject a POSIXct instead of `Sys.time()`.
#' @return invisible list(status, backup_path, restore_command, recorded_at).
mig010_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  if (!exists(".rc_resolve_one_analyte", mode = "function") ||
      !exists(".rc_load_registry", mode = "function")) {
    cli::cli_abort(
      "010-aroclor-mixture-names: `.rc_load_registry()` / `.rc_resolve_one_analyte()`
       are not visible - run this from a session where the package was loaded
       with {.code devtools::load_all(\".\")}. The success gate asks the
       PRODUCTION resolver whether any label's resolution moved.",
      class = "sampletidy_error"
    )
  }

  # ---- Step 0: marker ----
  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con,
      "SELECT version, applied_at FROM schema_version WHERE version = ?",
      params = list(.mig010_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))

  if (nrow(mine) > 0) {
    recorded_at <- mine$applied_at[[1]]
    # THE MARKER ALONE IS NOT EVIDENCE THE RENAMES ARE IN PLACE. 006 learned
    # this the hard way and its header says so: a marker plus a torn state
    # reported as "nothing to do" is worse than a loud failure, because the next
    # thing that reads these names is a published report. So re-ask the same
    # success gate, read-only.
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig010_verify_renames(check_con),
             finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("010-aroclor-mixture-names already applied at %s; all %d rename(s) and %d mask fix(es) re-verified; nothing to do.",
         format(recorded_at), length(.mig010_renames), length(.mig010_mask_fixes))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_,
                          recorded_at = recorded_at)))
  }

  # ---- Step 1: preconditions, read-only, BEFORE the backup ----
  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig010_check_preconditions(pre_con),
           finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))

  if (isTRUE(dry_run)) {
    logf("DRY RUN: %d analyte(s) would be renamed, with %d CAS correction(s) and
          %d long-form display name(s).",
         length(.mig010_renames), length(.mig010_renames), length(.mig010_mask_keys()))
    for (spec in .mig010_renames) {
      logf("DRY RUN:   %s (%s) -> %s (%s)", spec$from_name, spec$from_CAS,
           spec$to_name, spec$to_CAS)
    }
    for (spec in .mig010_mask_fixes) {
      logf("DRY RUN:   %s long mask %s -> %s (display name only; analyte and CAS unchanged)",
           spec$analyte_name, spec$from_long, spec$to_long)
    }
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  # ---- Step 2: verified backup ----
  backup_path <- mig010_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)

  recorded_at <- .mig010_default(.now, Sys.time())

  with_db_write(function(con) {
    counts_before <- mig010_counts_checksum(con)
    resolutions_before <- .mig010_label_resolutions(con)

    db_transaction(con, function(con) {
      for (spec in .mig010_renames) {
        db_update(
          con, "analyte", uuid = spec$uuid,
          changes = list(name = spec$to_name, CAS = spec$to_CAS),
          actor = .mig010_actor,
          reason = sprintf(
            "010: %s is the Aroclor MIXTURE ALS reports under EP131B (as Aroclors), not congener %s; name and CAS %s -> %s (relabel only, no value changes)",
            spec$to_name, spec$from_name, spec$from_CAS, spec$to_CAS))
        db_update(
          con, "analyte_mask",
          key = list(uuid_analyte = spec$uuid, variant = .mig010_mask_variant),
          changes = list(name = spec$to_long),
          actor = .mig010_actor,
          reason = sprintf(
            "010: long-form display name follows the rename, so v_analyte_long stops printing %s",
            spec$from_long))
      }

      # The two MASK-ONLY fixes. `analyte` is not touched for these - only the
      # display name - and the checksum proves it, because their name/CAS are
      # NOT among the blanked cells.
      for (spec in .mig010_mask_fixes) {
        db_update(
          con, "analyte_mask",
          key = list(uuid_analyte = spec$uuid, variant = .mig010_mask_variant),
          changes = list(name = spec$to_long),
          actor = .mig010_actor,
          reason = sprintf(
            "010: %s is not a real Aroclor - the commercial series has no such member - so the long-form display name for %s is corrected to match the analyte (display name only; analyte name and CAS unchanged)",
            spec$from_long, spec$analyte_name))
      }

      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig010_marker_version, recorded_at))

      mig010_verify(counts_before, mig010_counts_checksum(con))
      .mig010_verify_renames(con)

      # DELIBERATELY REDUNDANT, and the mutation testing says so out loud: this
      # comparison SURVIVED being neutered, because nothing reachable can move a
      # resolution without first moving something the checksum already froze.
      # `.rc_resolve_one_analyte()` is a function of `lab_method` (frozen whole)
      # and, on the CAS-suggestion branch only, of `analyte.CAS` - and that
      # branch is unreachable here because every name asked about is taken FROM
      # a lab_method row, so it always matches on the exact branch first.
      #
      # Kept anyway, for two things a checksum cannot say. It is a SMOKE TEST
      # that the production resolver still runs against the renamed registry at
      # all, and it is the gate that would still hold if the checksum's
      # exemptions were ever widened. Recorded as redundant rather than quietly
      # left looking protective.
      resolutions_after <- .mig010_label_resolutions(con)
      if (!identical(resolutions_before, resolutions_after)) {
        # Over the UNION of the two key sets, not just `before`'s: a lab_method
        # that vanished would index as NA and be reported as "nothing moved"
        # while `identical()` had already said otherwise.
        allk <- union(names(resolutions_before), names(resolutions_after))
        b <- unname(resolutions_before[allk])
        a <- unname(resolutions_after[allk])
        moved <- allk[is.na(b) | is.na(a) | b != a]
        moved_txt <- paste(utils::head(moved, 3), collapse = ", ")
        cli::cli_abort(
          "010-aroclor-mixture-names verify failed: renaming an analyte must not
           change how any LABEL resolves, but {length(moved)} moved (e.g.
           {moved_txt}).",
          class = "sampletidy_error"
        )
      }
      NULL
    })

    logf("Verify passed: %d analyte(s) renamed with their CAS, %d display-name-only mask fix(es); no analysis row changed; no label's resolution moved.",
         length(.mig010_renames), length(.mig010_mask_fixes))
    invisible(TRUE)
  }, db = db)

  logf("010-aroclor-mixture-names migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
