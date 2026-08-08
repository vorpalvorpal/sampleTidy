# Operator-run migration: apply Robin's 2026-08-08 registry rulings.
#
# Six small, unrelated corrections to the REGISTRY (analyte / lab_method).
# They are one migration rather than six because each is a handful of rows,
# they were all ruled at once, and one backup + one transaction + one marker is
# safer than six of each. Every step is separately verified, so a failure names
# the ruling that failed rather than "007 failed".
#
# NOT ONE `analysis` ROW CHANGES VALUE. Step 5 transiently NULLs and restores
# `analysis.uuid_lab` on three rows to get past a duckdb FK limitation, and the
# safety gate proves the end state is byte-identical.
#
# ---- THE SIX RULINGS ----
#
# (1) DELETE the ACIRL `field` `Total Dissolved Solids` lab_method.
#     It has ZERO analyses, is not on the A76 field allowlist, and its name is a
#     live ACIRL transcription label carrying 382 corpus rows. Left in place
#     those rows would import as FIELD readings: A79 never supersedes a field
#     reading, and 005 ranks it ABOVE the real ALS value. Third member of a
#     family already ruled on twice - the mojibake EC (deleted 2026-08-01,
#     change_log 9f59b10a) and the two TSS (2026-08-02, 29cfea72 / c8b85ce2) -
#     and `scratchpad/m6a_field_sweep.R` shows it is the last.
#
# (2) PREFERENCE values, the first users of the column 005 adds.
#     TDS is measured TWO different ways and the database has been conflating
#     them: `EA015` (gravimetric, dried at 180C, 661 analyses) and `EA016`
#     (calculated from electrical conductivity, 994) both feed analyte `TDS`.
#     They are not the same quantity - on the 5 samples carrying both, the
#     ratio ranges 0.64 to 1.33. Robin's ruling is one analyte with an encoded
#     preference, mirroring the pH field-vs-lab case: keep both, prefer the
#     measurement, fall back to the calculation when it is all there is.
#     Same shape for nitrite (see (3)).
#     Both rows are ALS lab rows, so `is_field`/`is_als` tie and ONLY the
#     preference key can separate them - which is why the column exists.
#
# (3) CONVERSION CONSTANT on ALS `Nitrite as NO2`.
#     `Nitrite as N` and `Nitrite as NO2` are ONE measurement on two reporting
#     bases - they even share a method code, `EK057G`. Analyte `NO2-N` is held
#     as N, so an as-NO2 value belongs there only after multiplying by
#     14.007/46.005. Measured on the ACIRL corpus, the two labels' values are
#     exactly that factor rounded at the reporting limits: 0.02 -> 0.06,
#     0.03 -> 0.10, and 0.01 -> 0.05 (floored at the as-NO2 RL).
#     `conversion_constant` applies at COMMIT, so this affects future imports
#     only. The 7 analyses already on that method are NOT touched, and the
#     reason is the OPPOSITE of what this note first claimed. It said their
#     values "do not sit at this factor and could not be explained". They sit
#     at it exactly (scratchpad/m6b_no2_*.R, 2026-08-08): the source numbers
#     0.06 / 0.10 / <0.05 are stored as 0.018 / 0.030 / rl 0.015, which is
#     x 0.3044669 to the digit on all seven. The legacy import ALREADY applied
#     the conversion; those rows are correct as they stand, and re-valuing them
#     would break them. This ruling makes the registry able to reproduce what
#     the legacy pipeline did rather than silently importing raw as-NO2 numbers
#     as if they were as-N.
#
#     The gap is also documented IN THE DATABASE, which is how it was found.
#     `lab_method.reported_as` = 'NO2' against `analyte.reported_as` = 'N',
#     set by migration 002 (PLAN-14 R-14.2), whose own tests record that the
#     backfill set `conversion_constant` for `Ammonia as NH3` and left the
#     other six enumerated names NA pending a ruling. Swept across the whole
#     registry (scratchpad/m6b_basis_sweep.R): exactly TWO methods report in a
#     basis their analyte does not, `Ammonia as NH3` (constant present) and
#     this one (missing). So this ruling closes the last one, and no package
#     code reads `reported_as` - `conversion_constant` alone does the
#     arithmetic, so there is no double-application risk.
#
# (4) CREATE two analytes.
#     `Decachlorobiphenyl` - a QC surrogate recovery (units %, 0 non-detects,
#     60-100), the only member of its reporting block with no analyte row while
#     twelve sibling surrogates have one. `Volume Purged` - groundwater purge
#     volume, ruled "useful metadata"; the registry already models
#     non-chemistry observations as analytes (`Standing water level`, `Stage`,
#     `Appearance`), so this is the existing convention, not a new one.
#
# (5) REPOINT the `EP071:` `>C10 - C16 Fraction` lab_method from `TRH-F2` to
#     `TRH-C11-C16`.
#     `>C10 - C16 Fraction` is the ONLY lab_method name in the database mapping
#     to two different analytes: 292 analyses under `EP080/071:` -> TRH-C11-C16,
#     and 3 under `EP071:` -> TRH-F2. F2 is *calculated* by ALS as the C10-C16
#     band minus naphthalene, and those three reports have no F2 line at all -
#     `EP071:` is the semivolatile-only suite, so there is no naphthalene to
#     subtract and no F2 to compute. The raw band was filed as a calculated
#     fraction. Fixing it also makes the label resolve unambiguously, verified
#     in the success gate.
#     (`TRH-C11-C16` is this database's name for the `>C10 - C16` band, not a
#     real NEPM band - the `analyte_mask` EPA variant already renders it
#     "Total Recoverable Hydrocarbons (C10 - C16)", and the same convention
#     shows in TRH-F3 -> "c17-c34" and TRH-F4 -> "c35-c40".)
#
# (6) CORRECT `SAR`'s UNITS from `mg/L` to the dimensionless `1`.
#     Sodium Adsorption Ratio is a RATIO - (Na) / sqrt((Ca + Mg) / 2) in
#     milliequivalents - and carries no units at all. The registry has it as
#     `mg/L`, which is simply wrong, and 253 committed analyses sit under that
#     label. Their NUMBERS are right (0.1 to 152 are ordinary SAR values); only
#     the label is wrong, so this relabels them and re-values nothing.
#     `1` rather than NULL or `_`: the database already has the convention -
#     `NTMI` uses `units = '1'` - and udunits accepts `1` as dimensionless.
#
#     WHY IT MATTERS BEYOND TIDINESS. It is the entire real-world load of
#     ruling 8's `units_missing` review arm: 485 of 48,752 crosstab rows on the
#     real corpus, all of them SAR, about two per file. The arm goes quiet the
#     moment the registry is right.
#
#     AND IT IS ONLY SAFE BECAUSE OF A GUARD ADDED ALONGSIDE IT. udunits reads
#     a BARE NUMBER as a dimensionless scale factor, and 17 corpus SAR rows
#     carry `units_raw = 1.89` - a value that landed in the units cell.
#     Against `mg/L` those rows ERROR and get reviewed. Against `1` they would
#     have CONVERTED, silently multiplied by 1.89, and ruling 8's value arm
#     could not see it (1.84 x 1.89 = 3.48 is an ordinary SAR number). So this
#     ruling shipped together with the `units_numeric` guard in
#     `.rc_resolve_units_values()`. Fixing this without that guard would have
#     replaced a caught error with a silent corruption.
#
# ---- DEPENDS ON 005 ----
# Step 2 writes `lab_method.preference`, a column 005 creates. Enforced by the
# 1005 marker check in step 0. This is a REAL dependency, unlike 006's
# deliberate non-dependency.
#
# ---- THE FK PRE-PASS (step 5) ----
# duckdb refuses to move `lab_method.uuid_analyte` while any `analysis` still
# references the method - measured, not assumed (scratchpad/r007_fkprobe.R):
# a plain UPDATE raises "Violates foreign key constraint because key uuid_lab
# ... is still referenced". So step 5 detaches the 3 analyses (uuid_lab NULL),
# repoints, and reattaches - and those statements must COMMIT SEPARATELY, so
# they run BEFORE the main transaction, exactly as `confirm_analyte_methods()`'s
# F.14 pre-pass does. The backup is taken first, so a crash inside the pre-pass
# is recoverable by restore. This is the one guarded exception in the file.
#
# NEVER invoked by package code (A50). Run it from a session where the package
# was loaded with `devtools::load_all(".")` - the verify gate calls the internal
# `.rc_load_registry()` / `.rc_resolve_one_analyte()`.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/007-registry-rulings.R", envir = env)
#   env$mig007_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig007_marker_version <- 1007L
.mig007_actor <- "007-registry-rulings"

#' Nitrite basis factor: mg/L as NO2 -> mg/L as N.
#' Molar masses NO2 = 46.005, N = 14.007.
.mig007_no2_to_n <- 14.007 / 46.005

.mig007_default <- function(x, default) if (is.null(x)) default else x

# ---- the rulings, declaratively ---------------------------------------------
# Every target is named by its NATURAL KEY (name / method / organisation), never
# by uuid. A uuid in a migration file is unreviewable and unverifiable; a
# natural key is both, and the lookup below refuses on 0 or >1 match rather than
# silently acting on the wrong row.

.mig007_delete_methods <- list(
  list(name = "Total Dissolved Solids", method = "field", organisation = "ACIRL")
)

.mig007_preferences <- list(
  list(name = "Total Dissolved Solids @180°C",
       method = "EA015: Total Dissolved Solids dried at 180 ± 5 °C",
       organisation = "ALS", preference = 100L),
  list(name = "Total Dissolved Solids (Calc.)",
       method = "EA016: Calculated TDS (from Electrical Conductivity)",
       organisation = "ALS", preference = 200L),
  list(name = "Nitrite as N",
       method = "EK057G:  Nitrite as N by Discrete Analyser",
       organisation = "ALS", preference = 100L),
  list(name = "Nitrite as NO2",
       method = "EK057G:  Nitrite as N by Discrete Analyser",
       organisation = "ALS", preference = 200L)
)

.mig007_conversions <- list(
  list(name = "Nitrite as NO2",
       method = "EK057G:  Nitrite as N by Discrete Analyser",
       organisation = "ALS", conversion_constant = .mig007_no2_to_n)
)

# THE `uuid` IS PINNED, AND THAT IS THE ONE PLACE A LITERAL UUID BELONGS IN THIS
# FILE. The rule above - name targets by natural key, never by uuid - is about
# LOOKUPS: a uuid used to find an existing row is unreviewable and can silently
# select the wrong one. These uuids find nothing; they are the value a brand-new
# row is created WITH.
#
# Pinning them is what makes migration 006's mapping CSV reviewable BEFORE any
# of this is applied. That file cross-checks `analyte` name against
# `uuid_analyte` so a hand-edit cannot drift the two apart - so the two labels
# that need these new analytes (`Decachlorobiphenyl`, `Volume Purged`) can only
# be listed once their uuids are knowable. Generated at runtime they would not
# be, and 006's CSV would have to be regenerated by machine between 007 and 006,
# i.e. reviewed at apply time rather than now. Pinned, the whole three-migration
# sequence is reproducible and reviewable in advance, and re-running it on a
# restored backup produces byte-identical rows.
#
# The precondition below refuses if either uuid is already in use.
.mig007_new_analytes <- list(
  list(uuid = "540ffdc7-f3a7-4e18-9db4-41300e3a8fa0",
       name = "Decachlorobiphenyl", units = "%", type = "QC", CAS = "2051-24-3"),
  list(uuid = "3eb6fc65-dbe1-4a7d-ab28-2e01dc752a94",
       name = "Volume Purged", units = "L", type = "quality", CAS = NA_character_)
)

#' Analyte units corrections. `from` is checked, not just overwritten: if the
#' registry has moved since the ruling, refuse rather than clobber.
.mig007_analyte_units <- list(
  list(name = "SAR", from = "mg/L", to = "1")
)

.mig007_repoints <- list(
  list(name = ">C10 - C16 Fraction",
       method = "EP071: Total Recoverable Hydrocarbons - NEPM 2013 Fractions",
       organisation = "ALS", from_analyte = "TRH-F2", to_analyte = "TRH-C11-C16")
)

#' Resolve one natural key to exactly one `lab_method.uuid`
#' @keywords internal
.mig007_one_method <- function(con, spec) {
  hit <- DBI::dbGetQuery(
    con,
    "SELECT uuid FROM lab_method WHERE name = ? AND organisation = ?
       AND method IS NOT DISTINCT FROM ?",
    params = list(spec$name, spec$organisation, spec$method)
  )
  if (nrow(hit) != 1L) {
    cli::cli_abort(
      "007-registry-rulings: the natural key (name {sQuote(spec$name)}, method
       {sQuote(spec$method)}, organisation {sQuote(spec$organisation)}) matches
       {nrow(hit)} lab_method rows, not exactly 1. Refusing rather than guessing
       which row a ruling meant.",
      class = "sampletidy_error"
    )
  }
  hit$uuid[[1]]
}

#' Resolve an analyte NAME to exactly one uuid
#' @keywords internal
.mig007_one_analyte <- function(con, name) {
  hit <- DBI::dbGetQuery(con, "SELECT uuid FROM analyte WHERE name = ?",
                         params = list(name))
  if (nrow(hit) != 1L) {
    cli::cli_abort(
      "007-registry-rulings: analyte {sQuote(name)} matches {nrow(hit)} rows,
       not exactly 1.",
      class = "sampletidy_error"
    )
  }
  hit$uuid[[1]]
}

#' Every precondition, checkable read-only, so a doomed run leaves no backup.
#' @keywords internal
.mig007_check_preconditions <- function(con) {
  if (!("preference" %in% DBI::dbListFields(con, "lab_method"))) {
    cli::cli_abort(
      "007-registry-rulings: `lab_method.preference` does not exist - migration
       005 has not been applied to this database, and ruling (2) writes that
       column.",
      class = "sampletidy_error"
    )
  }

  # (1) the methods to delete must exist AND carry no analyses.
  for (spec in .mig007_delete_methods) {
    u <- .mig007_one_method(con, spec)
    n <- as.integer(DBI::dbGetQuery(
      con, "SELECT COUNT(*) n FROM analysis WHERE uuid_lab = ?", params = list(u))$n)
    if (n != 0L) {
      cli::cli_abort(
        "007-registry-rulings: {sQuote(spec$name)} ({spec$organisation}) carries
         {n} analyses. The ruling to delete it rests on it being UNUSED, so a
         non-zero count means the premise no longer holds.",
        class = "sampletidy_error"
      )
    }
  }

  # (2)(3)(5) every other target must resolve to exactly one row.
  for (spec in c(.mig007_preferences, .mig007_conversions)) .mig007_one_method(con, spec)
  for (spec in .mig007_repoints) {
    u <- .mig007_one_method(con, spec)
    from <- .mig007_one_analyte(con, spec$from_analyte)
    .mig007_one_analyte(con, spec$to_analyte)
    cur <- DBI::dbGetQuery(con, "SELECT uuid_analyte FROM lab_method WHERE uuid = ?",
                           params = list(u))$uuid_analyte
    if (!identical(cur, from)) {
      cli::cli_abort(
        "007-registry-rulings: {sQuote(spec$name)} ({spec$method}) points at
         {cur}, not at {sQuote(spec$from_analyte)} ({from}) as the ruling
         assumes. Refusing - the registry moved since the ruling was made.",
        class = "sampletidy_error"
      )
    }
  }

  # (4) the analytes to create must NOT already exist - by NAME, and by the
  # PINNED uuid. The uuid half is what makes pinning safe: a literal uuid that
  # collided with an existing row would be an INSERT failure at best and a
  # silent identity clash at worst.
  for (spec in .mig007_new_analytes) {
    n <- as.integer(DBI::dbGetQuery(
      con, "SELECT COUNT(*) n FROM analyte WHERE name = ?", params = list(spec$name))$n)
    if (n != 0L) {
      cli::cli_abort(
        "007-registry-rulings: analyte {sQuote(spec$name)} already exists, so
         ruling (4) would create a duplicate.",
        class = "sampletidy_error"
      )
    }
    taken <- as.integer(DBI::dbGetQuery(
      con, "SELECT COUNT(*) n FROM analyte WHERE uuid = ?", params = list(spec$uuid))$n)
    if (taken != 0L) {
      cli::cli_abort(
        "007-registry-rulings: the uuid pinned for {sQuote(spec$name)}
         ({spec$uuid}) is already in use by another analyte. Migration 006's
         mapping names that uuid, so it cannot simply be changed here - work out
         why it collided.",
        class = "sampletidy_error"
      )
    }
  }
  # (6) the analyte must exist and still carry the units the ruling names.
  for (spec in .mig007_analyte_units) {
    got <- DBI::dbGetQuery(con, "SELECT units FROM analyte WHERE name = ?",
                           params = list(spec$name))$units
    if (length(got) != 1L) {
      cli::cli_abort(
        "007-registry-rulings: analyte {sQuote(spec$name)} matches {length(got)}
         rows, not exactly 1.",
        class = "sampletidy_error"
      )
    }
    if (!identical(got[[1]], spec$from)) {
      cli::cli_abort(
        "007-registry-rulings: analyte {sQuote(spec$name)} has units
         {sQuote(got[[1]])}, not {sQuote(spec$from)} as the ruling assumes.
         Refusing - the registry moved since the ruling was made.",
        class = "sampletidy_error"
      )
    }
  }
  invisible(TRUE)
}

# ---- step 5: the FK pre-pass -------------------------------------------------

#' Repoint a `lab_method.uuid_analyte` past duckdb's FK limitation
#'
#' Detach -> repoint -> reattach, in SEPARATELY COMMITTED statements (see the
#' file header). Returns the number of analyses that were detached and
#' restored, so the caller can assert none was left behind.
#' @keywords internal
.mig007_repoint_method <- function(con, uuid_lab, uuid_analyte, reason) {
  kids <- DBI::dbGetQuery(
    con, "SELECT uuid FROM analysis WHERE uuid_lab = ? ORDER BY uuid",
    params = list(uuid_lab))$uuid

  for (k in kids) {
    db_update(con, "analysis", uuid = k, changes = list(uuid_lab = NA_character_),
              actor = .mig007_actor, reason = paste(reason, "(FK detach)"))
  }
  db_update(con, "lab_method", uuid = uuid_lab,
            changes = list(uuid_analyte = uuid_analyte),
            actor = .mig007_actor, reason = reason)
  for (k in kids) {
    db_update(con, "analysis", uuid = k, changes = list(uuid_lab = uuid_lab),
              actor = .mig007_actor, reason = paste(reason, "(FK reattach)"))
  }

  # Scoped to the rows THIS call detached, not to the whole table. A global
  # "no NULL uuid_lab anywhere" check is wrong: a NULL `uuid_lab` is legal -
  # 005's mask views LEFT JOIN `lab_method` precisely because of it - so the
  # global form would refuse on a database that merely happened to contain one,
  # for a reason having nothing to do with this migration. Found by a surviving
  # mutation whose test setup left three rows detached beforehand.
  if (length(kids) > 0) {
    back <- DBI::dbGetQuery(
      con,
      sprintf("SELECT uuid FROM analysis WHERE uuid_lab = ? AND uuid IN (%s)",
              paste(rep("?", length(kids)), collapse = ", ")),
      params = c(list(uuid_lab), as.list(kids))
    )$uuid
    missing <- setdiff(kids, back)
    if (length(missing) > 0) {
      cli::cli_abort(
        "007-registry-rulings: {length(missing)} of {length(kids)} detached
         analysis row(s) were not reattached to {uuid_lab} - the pre-pass did
         not complete. Restore from the backup.",
        class = "sampletidy_error"
      )
    }
  }
  length(kids)
}

# ---- verify ------------------------------------------------------------------

#' Content of everything this migration must not change.
#' @keywords internal
mig007_counts_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  list(
    n_analysis = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n),
    n_sample = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM \"sample\"")$n),
    n_feature = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature")$n),
    # `analysis` INCLUDING uuid_lab: step 5 detaches and reattaches it, and this
    # is what proves the reattach put every row back exactly where it was.
    analysis = q("SELECT uuid, uuid_sample, uuid_lab, value, value_chr, quantified,
                         rl_low, rl_high, purpose, comments FROM analysis ORDER BY uuid"),
    sample = q("SELECT * FROM \"sample\" ORDER BY uuid"),
    feature = q("SELECT * FROM feature ORDER BY uuid")
  )
}

mig007_verify <- function(before, after) {
  bad <- names(before)[!vapply(names(before),
    function(n) identical(before[[n]], after[[n]]), logical(1))]
  if (length(bad) > 0) {
    cli::cli_abort(
      "007-registry-rulings verify failed: this migration changes only the
       REGISTRY, but {paste(bad, collapse = ', ')} moved.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

#' Every ruling, asserted individually against its post-state.
#' @keywords internal
.mig007_verify_rulings <- function(con) {
  fail <- function(...) cli::cli_abort(paste0("007-registry-rulings verify failed: ", ...),
                                       class = "sampletidy_error")

  for (spec in .mig007_delete_methods) {
    n <- as.integer(DBI::dbGetQuery(
      con, "SELECT COUNT(*) n FROM lab_method WHERE name = ? AND organisation = ?
              AND method IS NOT DISTINCT FROM ?",
      params = list(spec$name, spec$organisation, spec$method))$n)
    if (n != 0L) fail("(1) {sQuote(spec$name)} is still present.")
  }

  for (spec in .mig007_preferences) {
    got <- DBI::dbGetQuery(
      con, "SELECT preference FROM lab_method WHERE name = ? AND organisation = ?
              AND method IS NOT DISTINCT FROM ?",
      params = list(spec$name, spec$organisation, spec$method))$preference
    if (length(got) != 1L || is.na(got) || !identical(as.integer(got), spec$preference)) {
      fail("(2) {sQuote(spec$name)} has preference {got}, expected {spec$preference}.")
    }
  }

  for (spec in .mig007_conversions) {
    got <- DBI::dbGetQuery(
      con, "SELECT conversion_constant FROM lab_method WHERE name = ? AND organisation = ?
              AND method IS NOT DISTINCT FROM ?",
      params = list(spec$name, spec$organisation, spec$method))$conversion_constant
    if (length(got) != 1L || is.na(got) ||
        !isTRUE(all.equal(got, spec$conversion_constant))) {
      fail("(3) {sQuote(spec$name)} has conversion_constant {got}, expected {spec$conversion_constant}.")
    }
  }

  for (spec in .mig007_new_analytes) {
    got <- DBI::dbGetQuery(con, "SELECT uuid, units, type FROM analyte WHERE name = ?",
                           params = list(spec$name))
    if (nrow(got) != 1L) fail("(4) analyte {sQuote(spec$name)} was not created.")
    if (!identical(got$units[[1]], spec$units)) {
      fail("(4) analyte {sQuote(spec$name)} has units {got$units[[1]]}, expected {spec$units}.")
    }
    # The PINNED uuid, checked because migration 006's mapping CSV names it. If
    # this row landed under a generated uuid instead, 006 would refuse every
    # label pointing at it - and the failure would surface two migrations later.
    if (!identical(got$uuid[[1]], spec$uuid)) {
      fail("(4) analyte {sQuote(spec$name)} was created as {got$uuid[[1]]}, not the
            pinned {spec$uuid} that 006's mapping names.")
    }
  }

  for (spec in .mig007_analyte_units) {
    got <- DBI::dbGetQuery(con, "SELECT units FROM analyte WHERE name = ?",
                           params = list(spec$name))$units
    if (length(got) != 1L || !identical(got[[1]], spec$to)) {
      fail("(6) analyte {sQuote(spec$name)} has units {got}, expected {spec$to}.")
    }
    # NOT re-checked here: that the 253 committed analyses were RELABELLED
    # rather than re-valued. `mig007_verify()`'s SAFETY half already proves
    # `analysis` is byte-identical end to end, which is a strictly stronger
    # statement than any count this function could take, and it is proved by a
    # different mechanism. (It would also have needed a before-count threaded
    # into a function that takes only `con` - and a cli `{}` expression
    # starting with a dot, which reads as a style name, not a value.)
  }

  # (5) asked through the PRODUCTION resolver, not by re-reading the UPDATE:
  # the point of the repoint is that the LABEL now resolves unambiguously.
  registry <- .rc_load_registry(con)
  for (spec in .mig007_repoints) {
    want <- .mig007_one_analyte(con, spec$to_analyte)
    res <- .rc_resolve_one_analyte(spec$name, spec$organisation, NA_character_, registry)
    if (!identical(res$status, "resolved") || !identical(res$uuid_analyte, want)) {
      fail("(5) {sQuote(spec$name)} resolves {res$status} -> {res$uuid_analyte},
            expected resolved -> {spec$to_analyte} ({want}).")
    }
  }
  invisible(TRUE)
}

# ---- backup ------------------------------------------------------------------

.mig007_backup_counts <- function(con) {
  list(
    analyte = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analyte")$n),
    lab_method = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n),
    analysis = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n)
  )
}

mig007_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig007_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir,
                    sprintf("monitoring_pre-007-registry-rulings_%sZ.duckdb", ts))

  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig007_backup_counts(con)
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
  if (!identical(live_counts, .mig007_backup_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.",
                   class = "sampletidy_error")
  }
  dest
}

# ---- mig007_run() ------------------------------------------------------------

#' Run (or dry-run) the 007-registry-rulings migration
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory for the pre-migration backup.
#' @param dry_run if `TRUE`, check every precondition and write nothing.
#' @param .now inject a POSIXct instead of `Sys.time()`.
#' @param .uuid_fn inject a uuid generator (tests only).
#' @return invisible list(status, backup_path, restore_command, recorded_at).
mig007_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL,
                       .uuid_fn = uuid::UUIDgenerate) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  if (!exists(".rc_resolve_one_analyte", mode = "function")) {
    cli::cli_abort(
      "007-registry-rulings: `.rc_resolve_one_analyte()` is not visible - run
       this from a session where the package was loaded with
       {.code devtools::load_all(\".\")}.",
      class = "sampletidy_error"
    )
  }

  # ---- Step 0: markers ----
  marker_con <- st_connect(db, read_only = TRUE)
  markers <- tryCatch(
    DBI::dbGetQuery(marker_con,
      "SELECT version, applied_at FROM schema_version WHERE version IN (?, ?)",
      params = list(.mig007_marker_version, 1005L)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE)
  )
  mine <- markers[markers$version == .mig007_marker_version, ]
  if (nrow(mine) > 0) {
    logf("007-registry-rulings already applied at %s; nothing to do.",
         format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_,
                          recorded_at = mine$applied_at[[1]])))
  }
  if (!(1005L %in% markers$version)) {
    cli::cli_abort(
      "{db}: 005-preference-rank has not been applied (no 1005 marker), and
       ruling (2) writes `lab_method.preference`, which 005 creates.",
      class = "sampletidy_error"
    )
  }

  # ---- Step 1: preconditions, read-only, BEFORE the backup ----
  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig007_check_preconditions(pre_con),
           finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))

  if (isTRUE(dry_run)) {
    logf("DRY RUN: %d method(s) to delete, %d preference value(s), %d conversion
          constant(s), %d analyte(s) to create, %d repoint(s).",
         length(.mig007_delete_methods), length(.mig007_preferences),
         length(.mig007_conversions), length(.mig007_new_analytes),
         length(.mig007_repoints))
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  # ---- Step 2: backup BEFORE the pre-pass, which commits separately ----
  backup_path <- mig007_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)

  recorded_at <- .mig007_default(.now, Sys.time())

  result <- with_db_write(function(con) {
    counts_before <- mig007_counts_checksum(con)

    # ---- Step 3: the FK pre-pass (ruling 5), OUTSIDE the transaction ----
    for (spec in .mig007_repoints) {
      u <- .mig007_one_method(con, spec)
      to <- .mig007_one_analyte(con, spec$to_analyte)
      n <- .mig007_repoint_method(
        con, u, to,
        reason = sprintf("007 ruling (5): %s (%s) repointed from %s to %s",
                         spec$name, spec$method, spec$from_analyte, spec$to_analyte))
      logf("Ruling (5): repointed %s (%s), %d analysis row(s) detached and restored.",
           spec$name, spec$method, n)
    }

    db_transaction(con, function(con) {
      # (4) create analytes
      for (spec in .mig007_new_analytes) {
        db_append(con, "analyte", data.frame(
          uuid = spec$uuid, name = spec$name, units = spec$units,
          type = spec$type, CAS = spec$CAS, stringsAsFactors = FALSE),
          actor = .mig007_actor,
          reason = sprintf("007 ruling (4): %s created", spec$name))
      }
      # (1) delete unused methods
      for (spec in .mig007_delete_methods) {
        db_delete(con, "lab_method", uuid = .mig007_one_method(con, spec),
                  actor = .mig007_actor,
                  reason = sprintf("007 ruling (1): unused %s `%s` method deleted",
                                   spec$organisation, spec$name))
      }
      # (2) preference values
      for (spec in .mig007_preferences) {
        db_update(con, "lab_method", uuid = .mig007_one_method(con, spec),
                  changes = list(preference = spec$preference),
                  actor = .mig007_actor,
                  reason = sprintf("007 ruling (2): preference %d", spec$preference))
      }
      # (6) analyte units corrections
      for (spec in .mig007_analyte_units) {
        db_update(con, "analyte", uuid = .mig007_one_analyte(con, spec$name),
                  changes = list(units = spec$to),
                  actor = .mig007_actor,
                  reason = sprintf(
                    "007 ruling (6): %s is a dimensionless ratio; units %s -> %s (relabel only, no value changes)",
                    spec$name, spec$from, spec$to))
      }
      # (3) conversion constants
      for (spec in .mig007_conversions) {
        db_update(con, "lab_method", uuid = .mig007_one_method(con, spec),
                  changes = list(conversion_constant = spec$conversion_constant),
                  actor = .mig007_actor,
                  reason = "007 ruling (3): as-NO2 -> as-N basis conversion")
      }

      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig007_marker_version, recorded_at))

      mig007_verify(counts_before, mig007_counts_checksum(con))
      .mig007_verify_rulings(con)
      NULL
    })

    logf("Verify passed: all six rulings applied; no analysis row changed.")
    invisible(TRUE)
  }, db = db)

  logf("007-registry-rulings migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
