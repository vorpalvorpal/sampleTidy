#!/usr/bin/env Rscript
# =============================================================================
# NSW EPA annual monitoring-data return - Katoomba (site "K")
# =============================================================================
#
# Fills the blank EPA return template
#   dev/epa_monitoring_data_template.xlsx
# and writes a completed copy NEXT TO it (the template is never modified).
#
# Run:
#   Rscript dev/epa-monitoring-report.R
#   Rscript dev/epa-monitoring-report.R db=/path/to/monitoring.duckdb
#   Rscript dev/epa-monitoring-report.R nondetect=drop units=symbol
#
# Every setting in the "TUNABLES" block below can be overridden with a
# `key=value` command-line argument of the same name.
#
# -----------------------------------------------------------------------------
# ASSUMPTIONS AND DECISIONS - read these before sending anything to the EPA
# -----------------------------------------------------------------------------
#
# A. REPORTING WINDOW.  2025-05-27 to 2026-05-26, treated as BOTH ENDPOINTS
#    INCLUSIVE (365 local calendar days).  Nothing in the database records the
#    licence's reporting period, so the window is a parameter, not a lookup, and
#    the inclusivity convention could NOT be verified against an EPA source from
#    here.  It is applied as `local_date BETWEEN start AND end` on the
#    Australia/Sydney calendar date.  The one piece of supporting evidence is
#    arithmetic: 2025-05-27 to 2026-05-26 INCLUSIVE is exactly 365 days, which
#    is what you would expect an annual return to cover; reading the end date
#    as exclusive would give 364.  That is suggestive, not authoritative.
#    >>> Confirm against the licence. <<<
#
# B. LOCAL TIME.  `sample.datetime` is UTC-naive and correct; `sample.date` is
#    NOT usable (it stores Sydney midnight as a UTC-naive timestamp, so its
#    calendar date is one day early - it agrees with the true Sydney date in
#    only 2 of 15,111 rows in the rehearsal database).  This script uses
#    `datetime AT TIME ZONE 'UTC' AT TIME ZONE 'Australia/Sydney'` via the
#    DuckDB `icu` extension, which is INSTALLed and LOADed explicitly because
#    autoload does not work on a read-only connection.
#
# C. THE `v_measurement_epa` VIEW IS NOT USED - IT IS BROKEN.  Migration 001
#    rebuilt it filtering `feature_mask.variant = 'epa'` (lowercase) while the
#    data stores 'EPA' (uppercase), so it returns 0 rows.  Migration 001 also
#    stripped `date`, `datetime`, `analyte_name`, `analyte_units` and `site`
#    from `v_measurement`, and neither EPA view joins `analyte_mask` at all.
#    This script therefore queries the base tables directly.
#
# D. ALIAS INDIRECTION.  There is no `sample.uuid_feature` post-001.  The join
#    path is sample -> feature_alias (uuid) -> feature (uuid_feature).
#
# E. ANALYTE PATH.  There is no `analysis.uuid_analyte` either.  The path is
#    analysis -> lab_method (uuid_lab) -> analyte (uuid_analyte).
#
# F. SCOPE = EPA MASK NAMES ONLY.  A feature with no `feature_mask` row for
#    variant 'EPA' (or a NULL mask name), or an analyte with no `analyte_mask`
#    row for variant 'EPA' (or a NULL mask name), is OUT OF SCOPE.  Every such
#    drop is counted and printed - see the "DROPPED" sections of the console
#    report.  Nothing is dropped silently.
#
# G. NULL `analyte_mask.name`.  69 of the 142 EPA analyte-mask rows carry a
#    NULL name (some of them WITH units and a conversion constant - e.g. TSS,
#    Chloride, COD, H2S).  A NULL name means "there is no EPA-approved name for
#    this determinand", so those results are excluded and reported by name and
#    row count.  Several of them look like an unfinished mask rather than a
#    deliberate exclusion.  >>> Needs Robin's ruling. <<<
#
# H. UNITS.  Source of truth is `COALESCE(analyte_mask.units, analyte.units)` -
#    the same COALESCE the package's own `v_analyte_*` views use.  The template
#    spells units out in full ("milligrams per litre") while the mask stores the
#    symbol ("mg/L").  These are the SAME unit written two ways, so the script
#    does NOT ship a mismatch: `units="long"` (the default) renders each mask
#    symbol through the explicit `UNIT_LONG_FORM` lookup below, matching the
#    template's house style.  Any symbol NOT in that lookup is passed through
#    verbatim AND listed in the console report, so an unmapped unit is visible
#    rather than silently guessed.  `units="symbol"` emits the mask string
#    unchanged.
#
# I. CONVERSION CONSTANT - REAL AND APPLIED.  Reported value =
#    `analysis.value * COALESCE(analyte_mask.conversion_constant,
#    analyte.conversion_constant)`, matching the package's write-side
#    convention (R/commit.R `.ct_commit_analyses`, D7/A63: the constant is a
#    multiplier onto the stored value).  In scope for Katoomba this bites
#    exactly once and it matters: Methane is stored as L/L and reported to the
#    EPA as %v/v with a constant of 100, because licence 13089 M2.2 specifies
#    "percent by volume" and the R2.3 / M7.3 action threshold is "1% methane
#    (v/v)".  (It was masked as ppmv with a constant of 1e6 until 2026-07-23.)
#    Every constant actually applied is printed in the console report.
#
# J. UNIT MISMATCH GUARD.  If the stored units differ from the EPA units but
#    the conversion constant is 1, the numbers cannot be right.  Those rows are
#    EXCLUDED by default (`unit_mismatch=exclude`) and reported as a blocking
#    data defect; `unit_mismatch=include` emits them anyway.  This currently
#    catches "Standing water level", stored in metres but masked to the EPA as
#    "mg/L" with a constant of 1 - a groundwater level is not a concentration
#    and must not be filed as one.  >>> Needs Robin's ruling. <<<
#
# K. NON-DETECTS - THE BIGGEST OPEN QUESTION IN THIS SCRIPT.  Roughly 47% of
#    in-scope Katoomba results in the window are below the detection limit.
#    How they enter min/mean/max changes the numbers filed with the regulator.
#    Controlled by `NONDETECT` below:
#
#      "as_stored" (DEFAULT) - use `analysis.value` exactly as the database
#          holds it.  sampleTidy already substitutes the reporting limit into
#          `value` at ingest for lab non-detects, and the field gas meter
#          records 0 for methane non-detects.  This reports what the database
#          says, with no second guess.
#      "drop"    - non-detects contribute nothing to min/mean/max.  The sample
#          still counts as "collected and analysed"; a pollutant with no detects
#          at all gets a count but blank statistics.
#      "half"    - non-detects contribute `value / 2` (the conventional
#          half-the-reporting-limit substitution).
#
#    Substituting `analysis.rl_low` is deliberately NOT offered: in the
#    rehearsal data `rl_low` is unit-inconsistent with `value` for 127 of the
#    471 in-scope non-detects that have one (e.g. Dieldrin value 5e-4 mg/L
#    against rl_low 0.5 - a 1000x factor, i.e. rl_low left in ug/L).  Using it
#    would inflate those results by three orders of magnitude.
#    >>> Needs Robin's ruling on which of the three to file. <<<
#
# L. "No. of samples collected and analysed" = COUNT(DISTINCT sample) for that
#    EPA point x pollutant, not the number of result rows.  They differ where a
#    determinand is measured twice on one sample (in scope: pH, measured both in
#    the field and by the lab - 16 sample/pollutant pairs).  min/mean/max are
#    computed over ALL contributing results, so a doubly-measured sample carries
#    twice the weight in the mean.  The discrepancy is reported.
#
# M. COLUMNS LEFT BLANK FOR MANUAL COMPLETION.  "No. of samples required" is a
#    licence condition and is NOT in the database - verified: no table or column
#    anywhere in the schema records a required sampling frequency, count or
#    quota (`guideline` holds ANZECC concentration trigger values, which are a
#    different thing entirely).  Per Robin's instruction the column is emitted
#    with its header intact and GENUINELY EMPTY cells - not 0, not "NA", not a
#    placeholder - for him to fill in by hand.  Column order and header text are
#    exactly the template's.
#
# N. EPA POINT 1 IS AN AGGREGATE.  360 Katoomba gas features (K.G01 ... K.G364)
#    all carry the EPA mask name "1", so they are pooled into a single reported
#    row per pollutant.  That is what the mask says, and it matches licence
#    13089 P1.1, which defines point 1 as "landfill gas monitoring locations
#    conducted in a grid pattern over the landfill footprint" - one point, many
#    locations.  It is called out because it is easy to mistake for a bug.
#    NOTE the reported count is location-samples, not monitoring events; M2.2
#    says "Quarterly", which plainly means four EVENTS.  See section 4.4 of
#    dev/EPA-LICENCE-RECONCILIATION.md - still Robin's call.
#
# O. EPA POINT NUMBERING.  The Katoomba `feature_mask` rows were realigned to
#    licence 13089 V5 (dev/13089_V5.pdf, conditions P1.1 and P1.2) on
#    2026-07-23; before that they carried a different, undocumented scheme
#    (E01=1, gas=2, E02=14, MW01=1a ...).  K.MW02 and K.MW04 are NOT monitoring
#    points in V5, so their mask names were cleared and they no longer appear
#    in the return.  Blaxland and Lawson masks were deliberately NOT touched -
#    licence 13089 covers Katoomba only.
#
# =============================================================================

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
})

# ------------------------------------------------------------------ TUNABLES

TUNABLES <- list(
  # Database.  Defaults to st_config("live_db") so this targets the real
  # database after cutover; override with db=<path> for testing.
  db = NULL,

  site           = "K",
  window_start   = "2025-05-27",
  window_end     = "2026-05-26",   # inclusive - see assumption A

  nondetect      = "as_stored",    # as_stored | drop | half   - see K
  units          = "long",         # long | symbol             - see H
  unit_mismatch  = "exclude",      # exclude | include         - see J

  template       = NULL,           # defaults to dev/epa_monitoring_data_template.xlsx
  out            = NULL,           # defaults to dev/epa_monitoring_data_<site>_<start>_<end>.xlsx

  peek           = "1,2"           # EPA points echoed to the console at the end
)

# Symbol -> template house style.  Anything absent here passes through verbatim
# and is reported (assumption H).
UNIT_LONG_FORM <- c(
  "mg/L"          = "milligrams per litre",
  "µg/L"     = "micrograms per litre",
  "ug/L"          = "micrograms per litre",
  "mg/kg"         = "milligrams per kilogram",
  "µS/cm"    = "microsiemens per centimetre",
  "uS/cm"         = "microsiemens per centimetre",
  "ppmv"          = "parts per million by volume",
  "ppm"           = "parts per million",
  "%"             = "per cent",
  "%v/v"          = "per cent by volume",
  "pH"            = "pH units",
  "pH Unit"       = "pH units",
  "pH_Units"      = "pH units",
  "NTU"           = "nephelometric turbidity units",
  "g/m2/month"    = "grams per square metre per month",
  "m"             = "metres",
  "L/L"           = "litres per litre",
  "L/s"           = "litres per second",
  "mm"            = "millimetres",
  "degC"          = "degrees Celsius",
  "°C"       = "degrees Celsius"
)

# --------------------------------------------------------------------- SETUP

`%||%` <- function(x, y) if (is.null(x)) y else x

# Locate this script so the template path works from any working directory.
.script_path <- local({
  ca <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", ca[grepl("^--file=", ca)])
  if (length(f)) normalizePath(f[[1]], mustWork = FALSE) else NA_character_
})
DEV_DIR <- if (is.na(.script_path)) getwd() else dirname(.script_path)
PKG_ROOT <- dirname(DEV_DIR)

# key=value command-line overrides.
local({
  args <- commandArgs(trailingOnly = TRUE)
  kv <- args[grepl("^[a-z_]+=", args)]
  for (a in kv) {
    k <- sub("=.*$", "", a)
    v <- sub("^[^=]*=", "", a)
    if (!k %in% names(TUNABLES)) {
      stop("Unknown argument '", k, "'. Known: ", paste(names(TUNABLES), collapse = ", "))
    }
    TUNABLES[[k]] <<- v
  }
})

stopifnot(TUNABLES$nondetect %in% c("as_stored", "drop", "half"))
stopifnot(TUNABLES$units %in% c("long", "symbol"))
stopifnot(TUNABLES$unit_mismatch %in% c("exclude", "include"))

# Default DB path from st_config("live_db"), per the package's own config.
db_path <- TUNABLES$db
if (is.null(db_path)) {
  db_path <- tryCatch({
    if (requireNamespace("sampleTidy", quietly = TRUE)) {
      sampleTidy::st_config("live_db")
    } else {
      pkgload::load_all(PKG_ROOT, quiet = TRUE, export_all = FALSE, helpers = FALSE)
      sampleTidy::st_config("live_db")
    }
  }, error = function(e) {
    stop("Could not resolve st_config(\"live_db\") (", conditionMessage(e),
         "). Pass db=<path> explicitly.")
  })
}
if (!file.exists(db_path)) {
  stop("Database not found: ", db_path)
}

template <- TUNABLES$template %||% file.path(DEV_DIR, "epa_monitoring_data_template.xlsx")
if (!file.exists(template)) stop("Template not found: ", template)

out_path <- TUNABLES$out %||% file.path(
  DEV_DIR,
  sprintf("epa_monitoring_data_%s_%s_to_%s.xlsx",
          TUNABLES$site, TUNABLES$window_start, TUNABLES$window_end)
)
if (normalizePath(out_path, mustWork = FALSE) ==
    normalizePath(template, mustWork = FALSE)) {
  stop("Refusing to overwrite the template.")
}

hr <- function(title) cat("\n", strrep("=", 78), "\n", title, "\n",
                          strrep("=", 78), "\n", sep = "")
say <- function(...) cat(..., "\n", sep = "")

hr("NSW EPA annual monitoring-data return")
say("database : ", db_path)
say("template : ", template)
say("output   : ", out_path)
say("site     : ", TUNABLES$site)
say("window   : ", TUNABLES$window_start, " to ", TUNABLES$window_end,
    " inclusive (Australia/Sydney local date)")
say("non-detect handling : ", TUNABLES$nondetect)
say("unit rendering      : ", TUNABLES$units)
say("unit mismatch       : ", TUNABLES$unit_mismatch)

# ----------------------------------------------------------------- CONNECT

con <- dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# icu is required for the timezone conversion and must be LOADed explicitly:
# autoload does not work on a read-only connection.
invisible(dbExecute(con, "INSTALL icu;"))
invisible(dbExecute(con, "LOAD icu;"))

LOCAL_DATE <- "(s.datetime AT TIME ZONE 'UTC' AT TIME ZONE 'Australia/Sydney')::DATE"

bind <- list(TUNABLES$site, TUNABLES$window_start, TUNABLES$window_end)

# ------------------------------------------------------------------- FUNNEL
# Row counts at each filter stage, so every drop is visible.

funnel_sql <- sprintf("
WITH base AS (
  SELECT an.uuid AS uuid_analysis, f.uuid AS uuid_feature, f.site,
         lm.uuid_analyte, %s AS local_date
  FROM analysis an
  JOIN sample s        ON s.uuid  = an.uuid_sample
  JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
  JOIN feature f        ON f.uuid  = fa.uuid_feature
  JOIN lab_method lm    ON lm.uuid = an.uuid_lab
  JOIN analyte a        ON a.uuid  = lm.uuid_analyte
),
site_rows AS (SELECT * FROM base WHERE site = ?),
win_rows  AS (SELECT * FROM site_rows WHERE local_date BETWEEN ?::DATE AND ?::DATE),
feat_rows AS (SELECT * FROM win_rows w WHERE EXISTS (
   SELECT 1 FROM feature_mask fm
   WHERE fm.uuid_feature = w.uuid_feature AND fm.variant = 'EPA' AND fm.name IS NOT NULL)),
an_rows AS (SELECT * FROM feat_rows fr WHERE EXISTS (
   SELECT 1 FROM analyte_mask am
   WHERE am.uuid_analyte = fr.uuid_analyte AND am.variant = 'EPA' AND am.name IS NOT NULL))
SELECT (SELECT count(*) FROM base)      AS stage0_all_analyses,
       (SELECT count(*) FROM site_rows) AS stage1_site,
       (SELECT count(*) FROM win_rows)  AS stage2_in_window,
       (SELECT count(*) FROM feat_rows) AS stage3_feature_has_epa_name,
       (SELECT count(*) FROM an_rows)   AS stage4_analyte_has_epa_name
", LOCAL_DATE)

funnel <- dbGetQuery(con, funnel_sql, params = bind)

# --------------------------------------------------------------- DROP DETAIL

dropped_features <- dbGetQuery(con, sprintf("
SELECT f.name AS feature, count(*) AS n_results, count(DISTINCT s.uuid) AS n_samples
FROM analysis an
JOIN sample s         ON s.uuid  = an.uuid_sample
JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
JOIN feature f        ON f.uuid  = fa.uuid_feature
WHERE f.site = ? AND %s BETWEEN ?::DATE AND ?::DATE
  AND NOT EXISTS (SELECT 1 FROM feature_mask fm
                  WHERE fm.uuid_feature = f.uuid AND fm.variant = 'EPA'
                    AND fm.name IS NOT NULL)
GROUP BY 1 ORDER BY n_results DESC", LOCAL_DATE), params = bind)

dropped_analytes <- dbGetQuery(con, sprintf("
SELECT a.name AS analyte, a.units AS stored_units,
       max(CASE WHEN am.uuid_analyte IS NULL THEN 0 ELSE 1 END) AS has_epa_mask_row,
       count(*) AS n_results
FROM analysis an
JOIN sample s         ON s.uuid  = an.uuid_sample
JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
JOIN feature f        ON f.uuid  = fa.uuid_feature
JOIN lab_method lm    ON lm.uuid = an.uuid_lab
JOIN analyte a        ON a.uuid  = lm.uuid_analyte
LEFT JOIN analyte_mask am ON am.uuid_analyte = a.uuid AND am.variant = 'EPA'
WHERE f.site = ? AND %s BETWEEN ?::DATE AND ?::DATE
  AND EXISTS (SELECT 1 FROM feature_mask fm
              WHERE fm.uuid_feature = f.uuid AND fm.variant = 'EPA' AND fm.name IS NOT NULL)
  AND (am.uuid_analyte IS NULL OR am.name IS NULL)
GROUP BY 1, 2 ORDER BY n_results DESC", LOCAL_DATE), params = bind)

# ------------------------------------------------------------- IN-SCOPE ROWS

rows <- dbGetQuery(con, sprintf("
SELECT an.uuid                                     AS uuid_analysis,
       s.uuid                                      AS uuid_sample,
       %s                                          AS local_date,
       f.name                                      AS feature,
       fm.name                                     AS epa_point,
       a.name                                      AS stored_analyte,
       a.units                                     AS stored_units,
       am.name                                     AS pollutant,
       COALESCE(am.units, a.units)                 AS epa_units,
       COALESCE(am.conversion_constant, a.conversion_constant, 1.0) AS cc,
       an.value                                    AS value,
       an.quantified                               AS quantified,
       an.rl_low                                   AS rl_low,
       an.rl_high                                  AS rl_high
FROM analysis an
JOIN sample s          ON s.uuid  = an.uuid_sample
JOIN feature_alias fa  ON fa.uuid = s.uuid_feature_alias
JOIN feature f         ON f.uuid  = fa.uuid_feature
JOIN lab_method lm     ON lm.uuid = an.uuid_lab
JOIN analyte a         ON a.uuid  = lm.uuid_analyte
JOIN feature_mask fm   ON fm.uuid_feature = f.uuid AND fm.variant = 'EPA'
                      AND fm.name IS NOT NULL
JOIN analyte_mask am   ON am.uuid_analyte = a.uuid AND am.variant = 'EPA'
                      AND am.name IS NOT NULL
WHERE f.site = ? AND s.datetime IS NOT NULL
  AND %s BETWEEN ?::DATE AND ?::DATE
", LOCAL_DATE, LOCAL_DATE), params = bind)

# ------------------------------------------------- UNIT MISMATCH GUARD (J)

unit_check <- unique(rows[, c("pollutant", "stored_analyte", "stored_units", "epa_units", "cc")])
unit_check$mismatch <- with(unit_check,
  !is.na(stored_units) & !is.na(epa_units) & stored_units != epa_units & cc == 1)
mismatched <- unit_check[unit_check$mismatch, , drop = FALSE]
converted  <- unit_check[unit_check$cc != 1, , drop = FALSE]
rownames(mismatched) <- NULL
rownames(converted) <- NULL

# Match on the pollutant/stored-analyte PAIR, not the pollutant name alone: two
# stored analytes can share one EPA mask name, and only the offending one
# should be excluded.
.pair <- function(d) paste(d$pollutant, d$stored_analyte, sep = "\r")
if (nrow(mismatched) && identical(TUNABLES$unit_mismatch, "exclude")) {
  rows <- rows[!(.pair(rows) %in% .pair(mismatched)), , drop = FALSE]
}

# --------------------------------------------------- CONVERSION + NON-DETECT

rows$reported <- rows$value * rows$cc

is_nd <- !is.na(rows$quantified) & !rows$quantified

rows$stat_value <- rows$reported
if (identical(TUNABLES$nondetect, "drop")) {
  rows$stat_value[is_nd] <- NA_real_
} else if (identical(TUNABLES$nondetect, "half")) {
  rows$stat_value[is_nd] <- rows$reported[is_nd] / 2
}

# --------------------------------------------------------------- AGGREGATION

key <- paste(rows$epa_point, rows$pollutant, sep = "\r")
agg <- do.call(rbind, lapply(split(seq_len(nrow(rows)), key), function(ix) {
  d <- rows[ix, , drop = FALSE]
  v <- d$stat_value[!is.na(d$stat_value)]
  data.frame(
    epa_point   = d$epa_point[[1]],
    pollutant   = d$pollutant[[1]],
    epa_units   = d$epa_units[[1]],
    n_samples   = length(unique(d$uuid_sample)),
    n_results   = nrow(d),
    n_nondetect = sum(!is.na(d$quantified) & !d$quantified),
    lowest      = if (length(v)) min(v)  else NA_real_,
    mean        = if (length(v)) mean(v) else NA_real_,
    highest     = if (length(v)) max(v)  else NA_real_,
    stringsAsFactors = FALSE
  )
}))
if (is.null(agg)) {
  agg <- data.frame(epa_point = character(), pollutant = character(),
                    epa_units = character(), n_samples = integer(),
                    n_results = integer(), n_nondetect = integer(),
                    lowest = numeric(), mean = numeric(), highest = numeric())
}
rownames(agg) <- NULL

# Natural sort of EPA point IDs: "1", "1a", "2", "2a", "3", ... "10", "11".
num_part <- suppressWarnings(as.numeric(sub("^([0-9]+).*$", "\\1", agg$epa_point)))
sfx_part <- sub("^[0-9]+", "", agg$epa_point)
agg <- agg[order(num_part, sfx_part, agg$pollutant), , drop = FALSE]
rownames(agg) <- NULL

# --------------------------------------------------------- UNIT PRESENTATION

unmapped_units <- character()
render_units <- function(u) {
  if (identical(TUNABLES$units, "symbol")) return(u)
  out <- unname(UNIT_LONG_FORM[u])
  miss <- is.na(out) & !is.na(u)
  if (any(miss)) unmapped_units <<- union(unmapped_units, unique(u[miss]))
  out[miss] <- u[miss]
  out
}
agg$unit_out <- render_units(agg$epa_units)

# ---------------------------------------------------------- CONSOLE REPORT

hr("ROW COUNTS AT EACH FILTER STAGE (analysis rows)")
for (nm in names(funnel)) say(sprintf("  %-32s %8d", nm, funnel[[nm]][[1]]))
say(sprintf("  %-32s %8d", "dropped: feature has no EPA name",
            funnel$stage2_in_window - funnel$stage3_feature_has_epa_name))
say(sprintf("  %-32s %8d", "dropped: analyte has no EPA name",
            funnel$stage3_feature_has_epa_name - funnel$stage4_analyte_has_epa_name))

hr("DROPPED - Katoomba features in window with NO EPA mask name")
if (nrow(dropped_features)) print(dropped_features) else say("  (none)")

hr("DROPPED - analytes in window with NO EPA mask name")
if (nrow(dropped_analytes)) print(dropped_analytes) else say("  (none)")

hr("CONVERSION CONSTANTS APPLIED (value * cc)")
if (nrow(converted)) {
  print(converted[, c("pollutant", "stored_analyte", "stored_units", "epa_units", "cc")])
} else say("  (none - every in-scope analyte has conversion_constant = 1)")

hr("UNIT MISMATCH - stored units differ from EPA units with NO conversion")
if (nrow(mismatched)) {
  print(mismatched[, c("pollutant", "stored_analyte", "stored_units", "epa_units", "cc")])
  say("  -> action: ", TUNABLES$unit_mismatch,
      "  (these rows are ", if (TUNABLES$unit_mismatch == "exclude") "NOT" else "",
      " in the output)")
  say("  >>> DATA DEFECT - needs Robin's ruling <<<")
} else say("  (none)")

hr("NON-DETECTS IN SCOPE")
nd_total <- sum(is_nd)
say(sprintf("  in-scope results            : %d", nrow(rows)))
say(sprintf("  below detection (quantified = FALSE) : %d  (%.1f%%)",
            nd_total, 100 * nd_total / max(nrow(rows), 1)))
say(sprintf("  handling applied            : %s", TUNABLES$nondetect))
nd_rows <- rows[is_nd, , drop = FALSE]
say(sprintf("  non-detects with value == rl_low        : %d",
            sum(!is.na(nd_rows$rl_low) & nd_rows$value == nd_rows$rl_low)))
say(sprintf("  non-detects with value != rl_low        : %d   <- rl_low unit-inconsistent",
            sum(!is.na(nd_rows$rl_low) & nd_rows$value != nd_rows$rl_low)))
say(sprintf("  non-detects with rl_low NULL            : %d", sum(is.na(nd_rows$rl_low))))
say("  >>> Which substitution to file is Robin's call - see assumption K. <<<")

hr("REPEAT MEASUREMENTS (same sample, same pollutant, >1 result)")
rep_tbl <- as.data.frame(table(paste(rows$uuid_sample, rows$pollutant, sep = "\r")))
rep_keys <- as.character(rep_tbl$Var1[rep_tbl$Freq > 1])
if (length(rep_keys)) {
  say(sprintf("  %d sample/pollutant pairs have more than one result.", length(rep_keys)))
  say("  Pollutants affected: ",
      paste(sort(unique(sub("^.*\r", "", rep_keys))), collapse = ", "))
  say("  Column 5 counts DISTINCT SAMPLES; min/mean/max use every result.")
} else say("  (none)")

if (length(unmapped_units)) {
  hr("UNITS WITH NO LONG-FORM MAPPING (emitted verbatim)")
  say("  ", paste(unmapped_units, collapse = ", "))
}

hr("IN SCOPE FOR KATOOMBA IN THIS WINDOW")
say(sprintf("  EPA points  : %d  -> %s", length(unique(agg$epa_point)),
            paste(unique(agg$epa_point), collapse = ", ")))
say(sprintf("  pollutants  : %d", length(unique(agg$pollutant))))
say(sprintf("  output rows : %d", nrow(agg)))
say(sprintf("  samples     : %d", length(unique(rows$uuid_sample))))
if (nrow(rows)) {
  say(sprintf("  data spans  : %s to %s (local)",
              min(rows$local_date), max(rows$local_date)))
}

# --------------------------------------------------------------- WRITE XLSX

# The template's row 2 is green example text and row 6 an instruction line.
# Rather than delete them from a loaded copy (which would leave our real data
# sitting in the example's green cell style), the output workbook is built
# fresh and the eight headers are copied VERBATIM from the template, so column
# order and header text match exactly.
headers <- as.character(unlist(
  readxl::read_excel(template, sheet = 1, n_max = 1, col_names = FALSE,
                     .name_repair = "minimal")[1, ]
))
stopifnot(length(headers) == 8)

out <- data.frame(
  a = agg$epa_point,
  b = agg$pollutant,
  c = agg$unit_out,
  d = rep(NA_real_, nrow(agg)),   # No. of samples required - blank by design (M)
  e = agg$n_samples,
  f = agg$lowest,
  g = agg$mean,
  h = agg$highest,
  stringsAsFactors = FALSE
)
names(out) <- headers

wb <- openxlsx::createWorkbook()
openxlsx::addWorksheet(wb, "Sheet1")
openxlsx::writeData(wb, "Sheet1", out, colNames = TRUE, keepNA = FALSE)
openxlsx::addStyle(wb, "Sheet1",
                   openxlsx::createStyle(textDecoration = "bold", wrapText = TRUE,
                                         valign = "top"),
                   rows = 1, cols = 1:8, gridExpand = TRUE)
openxlsx::setColWidths(wb, "Sheet1", cols = 1:8,
                       widths = c(12, 42, 26, 16, 20, 16, 16, 16))
openxlsx::freezePane(wb, "Sheet1", firstRow = TRUE)
openxlsx::saveWorkbook(wb, out_path, overwrite = TRUE)

hr("WRITTEN")
say(out_path)
say("Template untouched: ", template)
say("")
say("Column 4 \"", headers[[4]], "\" is EMPTY BY DESIGN - licence condition,")
say("not held in the database. Robin fills it in by hand.")

# Show a couple of EPA points so the result is inspectable from the console.
PEEK_POINTS <- strsplit(TUNABLES$peek %||% "1,2", ",")[[1]]
hr(paste0("SAMPLE OF THE RESULT (EPA point", if (length(PEEK_POINTS) > 1) "s" else "",
          " ", paste(PEEK_POINTS, collapse = ", "), ")"))
peek <- agg[agg$epa_point %in% PEEK_POINTS, ]
old_width <- options(width = 200)
print(data.frame(
  Point      = peek$epa_point,
  Pollutant  = peek$pollutant,
  Unit       = peek$unit_out,
  Required   = NA_character_,
  Collected  = peek$n_samples,
  Lowest     = signif(peek$lowest, 6),
  Mean       = signif(peek$mean, 6),
  Highest    = signif(peek$highest, 6),
  check.names = FALSE
), row.names = FALSE)
options(old_width)

invisible(NULL)
