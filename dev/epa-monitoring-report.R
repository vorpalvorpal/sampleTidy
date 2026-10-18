#!/usr/bin/env Rscript
# =============================================================================
# NSW EPA annual monitoring-data return - per site
#   K  Katoomba WMF, licence 13089 (V5)
#   B  Blaxland WMF, licence 10039 (V28)
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
#   Rscript dev/epa-monitoring-report.R site=B
#
# Licence data lives in two CSVs beside this script, not in the code:
#   dev/epa_licence_requirements.csv  (site, point, pollutant) -> frequency and
#                                     required count - see assumption M
#   dev/epa_licence_points.csv        (site, point) -> role - see assumption N
# Per-site settings (licence number, reporting period, default peek) are in
# SITES below.  A site with no requirements rows stops before anything is
# written.
#
# Every setting in the "TUNABLES" block below can be overridden with a
# `key=value` command-line argument of the same name.
#
# -----------------------------------------------------------------------------
# ASSUMPTIONS AND DECISIONS - read these before sending anything to the EPA
# -----------------------------------------------------------------------------
#
# A. REPORTING WINDOW.  Per site, from `period_start` in SITES: Katoomba
#    27 May to 26 May, Blaxland 22 Aug to 21 Aug.  The default is the most
#    recent period that has fully ended; `window_start` / `window_end` override
#    it.  Both endpoints are INCLUSIVE (365 local calendar days).  Nothing in
#    the database records the licence's reporting period, so the window is a
#    setting, not a lookup, and the inclusivity convention could NOT be
#    verified against an EPA source from here.  It is applied as `local_date BETWEEN start AND end` on the
#    Australia/Sydney calendar date.  The one piece of supporting evidence is
#    arithmetic (Katoomba): 2025-05-27 to 2026-05-26 INCLUSIVE is exactly 365 days, which
#    is what you would expect an annual return to cover; reading the end date
#    as exclusive would give 364.  That is suggestive, not authoritative.
#    >>> Confirm against the licence. <<<
#
# B. LOCAL TIME.  `sample.datetime` and `sample.date` are both UTC-naive
#    instants, so CAST(... AS DATE) reads Sydney midnight a day early.  This
#    script uses `COALESCE(datetime, date) AT TIME ZONE 'UTC' AT TIME ZONE
#    'Australia/Sydney'` (date-only readings have no datetime) via the
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
#    variant 'EPA' (or a NULL or blank mask name), or an analyte with no `analyte_mask`
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
#    multiplier onto the stored value).  In scope at both sites this bites
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
#    in-scope Katoomba (K) results in the window are below the detection limit.
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
#          half-the-reporting-limit substitution).  NOTE this has no basis in
#          either licence - see assumption P.
#
#    Substituting `analysis.rl_low` is deliberately NOT offered: in the
#    rehearsal data `rl_low` is unit-inconsistent with `value` for 127 of the
#    471 in-scope non-detects that have one (e.g. Dieldrin value 5e-4 mg/L
#    against rl_low 0.5 - a 1000x factor, i.e. rl_low left in ug/L).  Using it
#    would inflate those results by three orders of magnitude.
#
#    RULED 2026-07-23: file "as_stored".  The licence states its own convention
#    (Dictionary, definition of 3DGM) and it is exactly this one - see
#    assumption P for the quotation and the caveat on its scope.
#
# L. "No. of samples collected and analysed" = the number of distinct SAMPLING
#    EVENTS for that EPA point x pollutant, where an event is one (feature,
#    Australia/Sydney local day) - the day being LOCAL_DATE, i.e.
#    COALESCE(datetime, date) converted from UTC.  It is neither the number of
#    result rows nor COUNT(DISTINCT sample).
#
#    RULED 2026-10-17.  Why not distinct samples: sample-matching rule A91 puts
#    the ACIRL field readings and the ALS lab readings from one visit into
#    SEPARATE samples, and 130 legacy field samples are already stored that
#    way, so a sample count would count one visit twice (in scope: pH, measured
#    both in the field and by the lab).  Two genuine visits to one feature on
#    one local day would count once; that is accepted.
#
#    min/mean/max are still computed over ALL contributing results, so a visit
#    with a field AND a lab result for one pollutant contributes both results
#    to the mean.  The repeat-measurement diagnostic reports how often.
#
# M. "No. of samples required" COMES FROM THE LICENCE, NOT THE DATABASE.  No
#    table or column anywhere in the schema records a required sampling
#    frequency, count or quota (`guideline` holds ANZECC concentration trigger
#    values, which are a different thing entirely).  The counts are therefore
#    transcribed from each licence's conditions M2.2 and M2.3 into
#    dev/epa_licence_requirements.csv, one row per (site, EPA point, EPA
#    pollutant), with group line items already expanded (`group_item`).
#    "Monthly" -> 12, "Quarterly" -> 4 and "Yearly" -> 1 over a 12-month
#    reporting period; the script refuses a row whose count disagrees with its
#    frequency.  A (point, pollutant) listed twice keeps the HIGHER count.  The
#    Katoomba rows were generated from the table this script used to build in
#    code, so they are unchanged; the Blaxland rows were transcribed from
#    licence 10039 V28 and checked against it independently.
#
#    THREE CASES DELIBERATELY LEAVE THE CELL EMPTY:
#      1. Discharge points (role "discharge": Katoomba 2 and 3, Blaxland 1).
#         M2.4(a) "Special Frequency 1" means "within the first 24 hours of
#         discharge" - one sample set per DISCHARGE EVENT.  The required number is the number of discharge
#         events in the period, which the database does not record.  Writing
#         4 or 1 here would be a false statement.
#      2. Any (point, pollutant) the licence does not require.  Roughly half
#         the rows in the return are extra data, not licence requirements.
#      3. Pollutants with no licence line item at all.
#    Empty cells are GENUINELY EMPTY - not 0, not "NA", not a placeholder.
#
#    GROUP LINE ITEMS.  The licence names one determinand where the mask has
#    many: "Organochlorine pesticides" / "Organophosphate pesticides" cover ~24
#    congeners, and "Total petroleum hydrocarbons" covers the TPH and TRH
#    fraction rows.  The group's frequency is applied to EVERY member row,
#    because each congener is analysed as part of that annual suite and leaving
#    them blank would read as "nothing required".  The console report lists
#    exactly which rows were filled this way.  The TPH/TRH fractions are now
#    enumerated in the CSV (they used to be matched by prefix at run time); a
#    prefixed fraction at a TPH point with no row is flagged in the console.
#    RULED 2026-07-23 (Robin): keep the expansion, required = 1.  This is a
#    large share of column 4 - 120 of 333 filled cells in 2023-24 and 96 of 324
#    in 2024-25 - so it is recorded here rather than left as a silent default.
#    (2025-26 expands nothing: the annual organics suite ran at K.S09, where the
#    licence does not require it, instead of at the bores where it does - see
#    section 3.3(b).  The 36 empty group rows there are a real gap, not a bug.)
#    The rejected alternative was section 4.4/18, collapsing the congeners into
#    the licence's own line-item names: closer to the licence and the EPA portal,
#    but it would average Lowest/Mean/Highest across chemically unrelated
#    congeners and discard detail the EPA currently receives.
#
#    Column order and header text are exactly the template's.  A row that the
#    licence requires but which was NEVER SAMPLED has no row in this return at
#    all (there is no data to aggregate), so the filed table understates the
#    gaps - see section 3.3 of dev/EPA-LICENCE-RECONCILIATION.md for the
#    required-but-absent pairs.
#
# N. POINT ROLES AND THE GAS GRID.  dev/epa_licence_points.csv gives each
#    site's licence points a role: gas_grid, discharge, surface_water,
#    groundwater, leachate, dust or weather.  Roles drive the empty discharge
#    cells (M), the footnote wording, and the exclusion of weather points
#    (Blaxland 27, condition M4), which this return does not cover.
#
#    THE GRID POINT IS AN AGGREGATE (Katoomba 1; Blaxland 10, 363 features
#    B.G001 ... B.G367).  At Katoomba, 360 gas features (K.G01 ... K.G364)
#    all carry the EPA mask name "1", so they are pooled into a single
#    reported row per pollutant.  That is what the mask says, and it matches licence
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
#    CONFIRMED 2026-07-23 (Robin): clearing K.MW02 and K.MW04 was the right
#    call, and K.L03 / K.L05 are to be LEFT UNMAPPED - only K.L01 and K.L04
#    carry point 18.  Both decisions are deliberate exclusions of real data
#    from the return, so they are stated here rather than inferred from the
#    masks: K.MW04 in particular is an actively sampled bore (121 rows across
#    3 samples in 2025-26, quarterly cadence) whose results are now omitted.
#    Nothing needs re-running for either - the live masks and the three filed
#    returns already reflect this.
#
#    Blaxland's masks already follow licence 10039 V28.  A mask name that is
#    '' or blank is treated exactly like NULL (B.L04 carried '' and would
#    otherwise surface as a blank point ID).
#
# P. BELOW-DETECTION VALUES ARE MARKED, NOT CHANGED.  sampleTidy's storage
#    convention is that a below-detection result carries the reporting limit in
#    `analysis.value` with `quantified = FALSE`.  Under the default
#    `nondetect="as_stored"` those limits therefore flow straight into
#    Lowest/Mean/Highest, and the filed table cannot distinguish "measured at
#    0.1" from "never detected, limit of reporting 0.1" - the template has eight
#    numeric columns and no way to write "<0.1".
#
#    Each licence's Dictionary (13089 and 10039 word it identically) is the
#    only place the licence states a
#    convention for non-detects.  In the definition of 3DGM: "Where one or more
#    of the samples is zero or below the detection limit for the analysis, then
#    1 or the detection limit respectively should be used in place of those
#    samples."  That is precisely `as_stored`, which is why it is the default.
#    Note the wording sits in the 3DGM definition, so it strictly governs the
#    L2.4 concentration limits at points 2 and 3 rather than the R1.5 return -
#    but it is the licence's own convention and the most defensible one here.
#    It also gives no support at all to the "half" substitution.
#
#    So the numbers are left exactly as they are and the AMBIGUITY IS MARKED
#    INSTEAD: any Lowest / Mean / Highest cell that is a reporting limit rather
#    than a measurement is written in GREY ITALICS, and a note at the foot of
#    the sheet explains the convention.  The rule per cell is:
#      Lowest / Highest - grey italic when EVERY result attaining that extreme
#          is below detection.  If a genuine detection ties the extreme, the
#          number IS a measurement and is left in normal type.
#      Mean             - grey italic only when EVERY contributing result for
#          that point x pollutant is below detection.  A mean mixing detects
#          and non-detects is left in normal type; it is a real quantity, just
#          a partly-substituted one.
#    Under nondetect="drop" non-detects contribute nothing, so nothing is ever
#    marked.  The workbook is written with openxlsx2.
#
# =============================================================================

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
  library(openxlsx2)
})

# ------------------------------------------------------------------ TUNABLES

TUNABLES <- list(
  # Database.  Defaults to st_config("live_db") so this targets the real
  # database after cutover; override with db=<path> for testing.
  db = NULL,

  site           = "K",            # a key of SITES below
  window_start   = NULL,           # default: from the site's period - see A
  window_end     = NULL,           # inclusive - see assumption A

  nondetect      = "as_stored",    # as_stored | drop | half   - see K
  units          = "long",         # long | symbol             - see H
  unit_mismatch  = "exclude",      # exclude | include         - see J

  template       = NULL,           # defaults to dev/epa_monitoring_data_template.xlsx
  out            = NULL,           # defaults to dev/epa_monitoring_data_<site>_<start>_<end>.xlsx

  extras         = "false",        # true | false - false (default) keeps only rows whose
                                   # (point, pollutant) is in the requirements table;
                                   # true also keeps extra data/mask pairs - see M
  requirements   = NULL,           # defaults to dev/epa_licence_requirements.csv - see M
  points         = NULL,           # defaults to dev/epa_licence_points.csv       - see N

  peek           = NULL            # EPA points echoed to the console at the end;
                                   # default: the site's `peek` in SITES
)

# Per-site licence settings.  The window defaults to the most recent complete
# reporting period: `period_start` (MM-DD) to the day before it a year later.
# `anniversary` is the licence's own anniversary date, quoted for the console
# only - note it is the period END at Katoomba but the period START at
# Blaxland, which is why the period is stated separately rather than derived.
SITES <- list(
  K = list(name = "Katoomba WMF", licence = "13089", licence_doc = "V5",
           anniversary = "26 May", period_start = "05-27", peek = "1,2",
           special_frequency_condition = "M2.4(a)"),
  B = list(name = "Blaxland WMF", licence = "10039", licence_doc = "V28",
           anniversary = "22 Aug", period_start = "08-22", peek = "1,10",
           special_frequency_condition = "M2.4(a)",
           notes = paste0(
             "Total dissolved solids at points 18, 20 and 22 is reported in ",
             "milligrams per litre, the unit in which it is measured. Condition ",
             "M2.3 gives micrograms per litre for these points, which appears to ",
             "be a typographical error: the same pollutant is specified in ",
             "milligrams per litre at every other point."))
)

# Licence frequency -> required number of samples over a 12-month period.
FREQUENCY_COUNT <- c(Monthly = 12L, Quarterly = 4L, Yearly = 1L)

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
  "CFU/100mL"     = "colony forming units per 100 millilitres",
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
stopifnot(tolower(TUNABLES$extras) %in% c("true", "false"))
EXTRAS <- identical(tolower(TUNABLES$extras), "true")

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

# ------------------------------------------- LICENCE REQUIREMENTS + POINTS
# Loaded and validated BEFORE anything else, so a site with no requirements
# stops here and no workbook is ever written for it (assumption M).

SITE <- TUNABLES$site
req_path <- TUNABLES$requirements %||% file.path(DEV_DIR, "epa_licence_requirements.csv")
pts_path <- TUNABLES$points %||% file.path(DEV_DIR, "epa_licence_points.csv")
for (f in c(req_path, pts_path)) if (!file.exists(f)) stop("Not found: ", f)

ALL_REQ <- utils::read.csv(req_path, colClasses = "character",
                           na.strings = "", strip.white = TRUE)
ALL_PTS <- utils::read.csv(pts_path, colClasses = "character",
                           na.strings = "", strip.white = TRUE)
stopifnot(all(c("site", "licence", "epa_point", "pollutant", "frequency",
                "required", "condition", "group_item") %in% names(ALL_REQ)),
          all(c("site", "epa_point", "role") %in% names(ALL_PTS)))

LICENCE_REQUIREMENTS <- ALL_REQ[ALL_REQ$site %in% SITE, , drop = FALSE]
POINTS <- ALL_PTS[ALL_PTS$site %in% SITE, , drop = FALSE]
if (!nrow(LICENCE_REQUIREMENTS)) {
  stop("No licence requirements for site '", SITE, "' in ", req_path,
       ". Transcribe the licence's monitoring conditions into that file before ",
       "generating a return; no workbook has been written.", call. = FALSE)
}
if (!nrow(POINTS)) {
  stop("No licence monitoring points for site '", SITE, "' in ", pts_path,
       "; no workbook has been written.", call. = FALSE)
}
if (is.null(SITES[[SITE]])) {
  stop("No per-site settings for site '", SITE, "' in SITES; no workbook has ",
       "been written.", call. = FALSE)
}
S <- SITES[[SITE]]

ROLES <- c("gas_grid", "discharge", "surface_water", "groundwater", "leachate",
           "dust", "weather")
if (any(bad <- !POINTS$role %in% ROLES)) {
  stop("Unknown role(s) in ", pts_path, ": ",
       paste(unique(POINTS$role[bad]), collapse = ", "))
}
if (anyDuplicated(POINTS$epa_point)) stop("Duplicate EPA point in ", pts_path)
PT_ROLE <- function(role) POINTS$epa_point[POINTS$role %in% role]
PT_DISCHARGE   <- PT_ROLE("discharge")   # Special Frequency 1: per discharge event
PT_GRID        <- PT_ROLE("gas_grid")    # pooled grid of gas locations
PT_NOT_REPORTED <- PT_ROLE("weather")    # licence point, but not in this return

local({
  r <- LICENCE_REQUIREMENTS
  if (!all(r$licence == S$licence)) {
    stop("Requirements for site '", SITE, "' cite licence(s) ",
         paste(unique(r$licence), collapse = ", "), ", not ", S$licence)
  }
  if (length(miss <- setdiff(r$epa_point, POINTS$epa_point))) {
    stop("Requirements name EPA point(s) not in ", pts_path, ": ",
         paste(miss, collapse = ", "))
  }
  if (any(bad <- !r$frequency %in% c(names(FREQUENCY_COUNT), "Special Frequency 1"))) {
    stop("Unknown frequency: ", paste(unique(r$frequency[bad]), collapse = ", "))
  }
  want <- unname(FREQUENCY_COUNT[r$frequency])          # NA for Special Frequency
  got  <- suppressWarnings(as.integer(r$required))
  if (any(bad <- !(is.na(want) & is.na(got)) & !(!is.na(want) & !is.na(got) & want == got))) {
    stop("Required count disagrees with frequency in ", req_path, " at: ",
         paste(utils::head(paste0(r$epa_point[bad], "/", r$pollutant[bad]), 5),
               collapse = "; "))
  }
  if (any(!is.na(got) & r$epa_point %in% PT_DISCHARGE)) {
    stop("A discharge (Special Frequency 1) point carries a required count")
  }
})
LICENCE_REQUIREMENTS$required <- as.integer(LICENCE_REQUIREMENTS$required)
LICENCE_REQUIREMENTS$group_item[is.na(LICENCE_REQUIREMENTS$group_item)] <- ""

# A (point, pollutant) appearing in two conditions keeps the HIGHER count.
LICENCE_REQUIREMENTS <- do.call(rbind, lapply(
  split(LICENCE_REQUIREMENTS, paste(LICENCE_REQUIREMENTS$epa_point,
                                    LICENCE_REQUIREMENTS$pollutant, sep = "\r")),
  function(d) {
    if (all(is.na(d$required))) d[1, , drop = FALSE]
    else d[which.max(d$required), , drop = FALSE]
  }))
rownames(LICENCE_REQUIREMENTS) <- NULL

# Reporting window (assumption A).  Explicit window_* arguments override.
local({
  ws <- TUNABLES$window_start; we <- TUNABLES$window_end
  shift_year <- function(d, n) {
    d <- as.POSIXlt(d); d$year <- d$year + n; as.Date(d)
  }
  if (is.null(ws) && is.null(we)) {
    today <- as.Date(format(Sys.time(), tz = "Australia/Sydney"))
    ws <- as.Date(paste0(format(today, "%Y"), "-", S$period_start))
    # Latest period that has fully ENDED before today.
    while (shift_year(ws, 1) - 1 >= today) ws <- shift_year(ws, -1)
    we <- shift_year(ws, 1) - 1
  } else if (is.null(we)) {
    ws <- as.Date(ws); we <- shift_year(ws, 1) - 1
  } else if (is.null(ws)) {
    we <- as.Date(we); ws <- shift_year(we + 1, -1)
  }
  TUNABLES$window_start <<- format(as.Date(ws))
  TUNABLES$window_end   <<- format(as.Date(we))
})
if (TUNABLES$window_end < TUNABLES$window_start) stop("window_end is before window_start")

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
say("site     : ", TUNABLES$site, " (", S$name, ", licence ", S$licence, " ",
    S$licence_doc, ", anniversary ", S$anniversary, ")")
say("licence data : ", req_path, " (", nrow(LICENCE_REQUIREMENTS), " rows), ",
    pts_path, " (", nrow(POINTS), " points)")
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

# COALESCE: date-only readings (dust, gas, some ACIRL field data) carry no
# datetime; their `date` holds the same UTC-naive instant convention, so it
# converts to the right Sydney day (migration 022 did the same for the views).
LOCAL_DATE <- "(COALESCE(s.datetime, s.date) AT TIME ZONE 'UTC' AT TIME ZONE 'Australia/Sydney')::DATE"

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
   WHERE fm.uuid_feature = w.uuid_feature AND fm.variant = 'EPA' AND NULLIF(TRIM(fm.name), '') IS NOT NULL)),
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
                    AND NULLIF(TRIM(fm.name), '') IS NOT NULL)
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
              WHERE fm.uuid_feature = f.uuid AND fm.variant = 'EPA' AND NULLIF(TRIM(fm.name), '') IS NOT NULL)
  AND (am.uuid_analyte IS NULL OR am.name IS NULL)
GROUP BY 1, 2 ORDER BY n_results DESC", LOCAL_DATE), params = bind)

# ------------------------------------------------------------- IN-SCOPE ROWS

rows <- dbGetQuery(con, sprintf("
SELECT an.uuid                                     AS uuid_analysis,
       s.uuid                                      AS uuid_sample,
       %s                                          AS local_date,
       f.uuid                                      AS uuid_feature,
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
                      AND NULLIF(TRIM(fm.name), '') IS NOT NULL
JOIN analyte_mask am   ON am.uuid_analyte = a.uuid AND am.variant = 'EPA'
                      AND am.name IS NOT NULL
WHERE f.site = ? AND COALESCE(s.datetime, s.date) IS NOT NULL
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

# Carried as a COLUMN so it survives split()/aggregation - the per-cell marking
# in assumption P needs to know which individual results were non-detects.
rows$is_nd <- !is.na(rows$quantified) & !rows$quantified
is_nd <- rows$is_nd

rows$stat_value <- rows$reported
if (identical(TUNABLES$nondetect, "drop")) {
  rows$stat_value[is_nd] <- NA_real_
} else if (identical(TUNABLES$nondetect, "half")) {
  rows$stat_value[is_nd] <- rows$reported[is_nd] / 2
}

# --------------------------------------------------------------- AGGREGATION

# Assumption L: one sampling event = one (feature, Sydney local day).
event_key <- function(d) paste(d$uuid_feature, d$local_date, sep = "\r")
n_sampling_events <- function(d) length(unique(event_key(d)))

key <- paste(rows$epa_point, rows$pollutant, sep = "\r")
agg <- do.call(rbind, lapply(split(seq_len(nrow(rows)), key), function(ix) {
  d    <- rows[ix, , drop = FALSE]
  keep <- !is.na(d$stat_value)
  v    <- d$stat_value[keep]
  nd   <- d$is_nd[keep]          # aligned with v, so v == lo indexes nd correctly
  lo   <- if (length(v)) min(v)  else NA_real_
  hi   <- if (length(v)) max(v)  else NA_real_
  data.frame(
    epa_point   = d$epa_point[[1]],
    pollutant   = d$pollutant[[1]],
    epa_units   = d$epa_units[[1]],
    n_samples   = n_sampling_events(d),   # assumption L
    n_results   = nrow(d),
    n_nondetect = sum(!is.na(d$quantified) & !d$quantified),
    lowest      = lo,
    mean        = if (length(v)) mean(v) else NA_real_,
    highest     = hi,
    # Assumption P.  A tie between a detect and a non-detect at the extreme
    # leaves the cell unmarked: the number is a real measurement.
    lowest_nd   = length(v) > 0 && all(nd[v == lo]),
    mean_nd     = length(v) > 0 && all(nd),
    highest_nd  = length(v) > 0 && all(nd[v == hi]),
    stringsAsFactors = FALSE
  )
}))
if (is.null(agg)) {
  agg <- data.frame(epa_point = character(), pollutant = character(),
                    epa_units = character(), n_samples = integer(),
                    n_results = integer(), n_nondetect = integer(),
                    lowest = numeric(), mean = numeric(), highest = numeric(),
                    lowest_nd = logical(), mean_nd = logical(),
                    highest_nd = logical())
}
rownames(agg) <- NULL

# Natural sort of EPA point IDs: "1", "1a", "2", "2a", "3", ... "10", "11".
num_part <- suppressWarnings(as.numeric(sub("^([0-9]+).*$", "\\1", agg$epa_point)))
sfx_part <- sub("^[0-9]+", "", agg$epa_point)
agg <- agg[order(num_part, sfx_part, agg$pollutant), , drop = FALSE]
rownames(agg) <- NULL

# Point numbers in prose: "point 1", "points 2 and 3", "points 7, 8 and 10".
name_points <- function(p) {
  p <- p[order(suppressWarnings(as.numeric(sub("^([0-9]+).*$", "\\1", p))), p)]
  if (!length(p)) return("no point")
  if (length(p) == 1) return(paste("point", p))
  paste0("points ", paste(head(p, -1), collapse = ", "), " and ", tail(p, 1))
}
# The licence frequency word for a grid point's requirement (e.g. "Quarterly").
grid_frequency <- function(gp) {
  f <- unique(LICENCE_REQUIREMENTS$frequency[LICENCE_REQUIREMENTS$epa_point == gp &
                                               !is.na(LICENCE_REQUIREMENTS$required)])
  if (length(f) == 1) f else "required"
}

# ------------------------------------------------- LICENCE REQUIRED COUNTS (M)
# LICENCE_REQUIREMENTS was loaded from the requirements CSV at the top (one row
# per point x EPA pollutant, group line items already expanded).

agg$required <- LICENCE_REQUIREMENTS$required[
  match(paste(agg$epa_point, agg$pollutant, sep = "\r"),
        paste(LICENCE_REQUIREMENTS$epa_point, LICENCE_REQUIREMENTS$pollutant,
              sep = "\r"))]

# Discharge points: Special Frequency 1, per discharge event, number unknown -
# must stay empty (M).
agg$required[agg$epa_point %in% PT_DISCHARGE] <- NA_integer_

# Points the licence names but which this return does not cover (weather, M4),
# and points the points file does not know at all.
not_reported <- agg[agg$epa_point %in% PT_NOT_REPORTED, , drop = FALSE]
agg <- agg[!agg$epa_point %in% PT_NOT_REPORTED, , drop = FALSE]
rows <- rows[!rows$epa_point %in% PT_NOT_REPORTED, , drop = FALSE]
rownames(agg) <- NULL
unknown_points <- setdiff(unique(agg$epa_point), POINTS$epa_point)

# Group line items (OCP/OPP congeners, TPH/TRH fractions) - see M.
GROUPED_KEYS <- with(LICENCE_REQUIREMENTS[LICENCE_REQUIREMENTS$group_item != "", ],
                     paste(epa_point, pollutant, sep = "\r"))
# A TPH/TRH-prefixed pollutant with no requirements row is probably a new
# fraction the CSV has not caught up with - flag it rather than leave it blank.
HYDROCARBON_RX <- "^(Total Petroleum Hydrocarbons|Total Recoverable Hydrocarbons)"
tph_points <- unique(LICENCE_REQUIREMENTS$epa_point[LICENCE_REQUIREMENTS$group_item == "TPH"])
new_fractions <- agg[grepl(HYDROCARBON_RX, agg$pollutant) & is.na(agg$required) &
                       agg$epa_point %in% tph_points, , drop = FALSE]

# Required pairs with no data in the window (assumption M: they have no row).
req_counted <- LICENCE_REQUIREMENTS[!is.na(LICENCE_REQUIREMENTS$required) &
                                      !LICENCE_REQUIREMENTS$epa_point %in% PT_NOT_REPORTED, ]
no_data <- req_counted[!paste(req_counted$epa_point, req_counted$pollutant, sep = "\r") %in%
                         paste(agg$epa_point, agg$pollutant, sep = "\r"), ]

# Default (extras=false): keep only (point, pollutant) pairs that are in the
# requirements table for this site (membership, not a non-blank count).
if (!EXTRAS) {
  .kk <- function(p, q) paste(p, q, sep = "\r")
  .in_req <- .kk(agg$epa_point, agg$pollutant) %in%
    .kk(LICENCE_REQUIREMENTS$epa_point, LICENCE_REQUIREMENTS$pollutant)
  extras_dropped <- agg[!.in_req, , drop = FALSE]
  agg <- agg[.in_req, , drop = FALSE]
  rows <- rows[.kk(rows$epa_point, rows$pollutant) %in% .kk(agg$epa_point, agg$pollutant), ,
               drop = FALSE]
  rownames(agg) <- NULL
  hr("EXTRAS EXCLUDED (extras=false)")
  say(sprintf("  %d row(s) with data but no requirements row left out; extras=true keeps them",
              nrow(extras_dropped)))
}

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

hr(paste0("DROPPED - site ", SITE, " features in window with NO EPA mask name"))
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
say("  (ruled 2026-07-23: as_stored, per the licence Dictionary - assumption P)")

hr("REPEAT MEASUREMENTS (same feature, same local day, same pollutant, >1 result)")
rep_tbl <- as.data.frame(table(paste(event_key(rows), rows$pollutant, sep = "\r")))
rep_keys <- as.character(rep_tbl$Var1[rep_tbl$Freq > 1])
if (length(rep_keys)) {
  say(sprintf("  %d event/pollutant pairs have more than one result.", length(rep_keys)))
  say("  Pollutants affected: ",
      paste(sort(unique(sub("^.*\r", "", rep_keys))), collapse = ", "))
  say("  Column 5 counts SAMPLING EVENTS (feature x local day, assumption L);")
  say("  min/mean/max use every result.")
} else say("  (none)")

if (length(unmapped_units)) {
  hr("UNITS WITH NO LONG-FORM MAPPING (emitted verbatim)")
  say("  ", paste(unmapped_units, collapse = ", "))
}

hr("LICENCE REQUIRED COUNTS (column 4)")
say(sprintf("  rows with a required count : %d of %d", sum(!is.na(agg$required)),
            nrow(agg)))
say(sprintf("  rows left EMPTY            : %d", sum(is.na(agg$required))))
say(sprintf("    - %s, per discharge event (%s) : %d",
            name_points(PT_DISCHARGE), S$special_frequency_condition,
            sum(agg$epa_point %in% PT_DISCHARGE)))
say(sprintf("    - not a licence requirement at that point : %d",
            sum(is.na(agg$required) & !agg$epa_point %in% PT_DISCHARGE)))
grouped_filled <- agg[!is.na(agg$required) &
                        paste(agg$epa_point, agg$pollutant, sep = "\r") %in% GROUPED_KEYS, ]
say(sprintf("  filled from a GROUP line item (judgement call, see M) : %d",
            nrow(grouped_filled)))
if (nrow(grouped_filled)) {
  say("    pollutants: ",
      paste(sort(unique(grouped_filled$pollutant)), collapse = ", "))
}
short <- agg[!is.na(agg$required) & agg$n_samples < agg$required, ]
say(sprintf("  SHORT of the required frequency : %d of %d rows with a count",
            nrow(short), sum(!is.na(agg$required))))
if (nrow(short)) {
  s <- short[order(short$required - short$n_samples, decreasing = TRUE), ]
  say("    worst shortfalls:")
  for (i in seq_len(min(6, nrow(s)))) {
    say(sprintf("      pt %-3s %-34s %d of %d", s$epa_point[i],
                substr(s$pollutant[i], 1, 34), s$n_samples[i], s$required[i]))
  }
}
for (gp in intersect(PT_GRID, agg$epa_point)) {
  say("  NOTE point ", gp, ": 'collected' counts grid LOCATION-DAYS, the licence's")
  say("  '", grid_frequency(gp), "' means monitoring EVENTS. The two are not comparable.")
}
if (nrow(new_fractions)) {
  say("  >>> TPH/TRH fraction(s) with no requirements row at a TPH point - add them")
  say("      to ", basename(req_path), " if they belong to the group: ",
      paste(unique(new_fractions$pollutant), collapse = ", "))
}

if (nrow(not_reported)) {
  hr("NOT REPORTED - licence points outside this return (weather, M4)")
  say(sprintf("  %d row(s) at point(s) %s omitted", nrow(not_reported),
              paste(unique(not_reported$epa_point), collapse = ", ")))
}
if (length(unknown_points)) {
  hr("WARNING - EPA points in the feature mask but NOT in the licence points file")
  say("  ", paste(unknown_points, collapse = ", "), "   (", pts_path, ")")
}

hr(paste0("IN SCOPE FOR SITE ", SITE, " IN THIS WINDOW"))
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
  d = agg$required,               # from the licence, not the DB - see (M)
  e = agg$n_samples,
  f = agg$lowest,
  g = agg$mean,
  h = agg$highest,
  stringsAsFactors = FALSE
)
names(out) <- headers

FONT  <- "Calibri"     # not the openxlsx2 default (Aptos Narrow), which older
FSIZE <- "11"          # Excel installations do not have
GREY  <- wb_color(hex = "FF808080")

# Data rows start at sheet row 2 (row 1 is the header).  Columns F, G, H are
# Lowest, Mean, Highest.
DATA_ROW1 <- 2L
LAST_ROW  <- nrow(out) + DATA_ROW1 - 1L
NOTE_ROW  <- LAST_ROW + 2L

wb <- wb_workbook()
wb$add_worksheet("Sheet1")
wb$set_base_font(font_size = FSIZE, font_name = FONT)
# na = NULL writes GENUINELY EMPTY cells.  The openxlsx2 default writes the
# #N/A error literal, which would violate assumption M.
wb$add_data(x = out, col_names = TRUE, na = NULL)
wb$add_font(dims = "A1:H1", bold = "1", name = FONT, size = FSIZE)
wb$add_cell_style(dims = "A1:H1", wrap_text = "1", vertical = "top")
wb$set_col_widths(cols = 1:8, widths = c(12, 42, 26, 16, 20, 16, 16, 16))
wb$freeze_pane(first_row = TRUE)

# --- assumption P: mark reporting limits, do not change them ----------------
mark_nd <- function(col_letter, flags) {
  idx <- which(flags)
  if (!length(idx)) return(0L)
  # Chunked: one dims string with several hundred scattered refs is accepted
  # but needlessly large.
  for (chunk in split(idx, ceiling(seq_along(idx) / 200))) {
    wb$add_font(dims = paste0(col_letter, chunk + DATA_ROW1 - 1L, collapse = ","),
                italic = "1", color = GREY, name = FONT, size = FSIZE)
  }
  length(idx)
}
n_marked <- c(
  Lowest  = mark_nd("F", agg$lowest_nd),
  Mean    = mark_nd("G", agg$mean_nd),
  Highest = mark_nd("H", agg$highest_nd)
)

# --- footnote ---------------------------------------------------------------

# Not every below-detection result is a reporting limit: a field instrument may
# record a true zero (in scope at Katoomba and Blaxland this is methane only).
# The sentence is emitted only when such results are actually present, so the
# note stays true for any site/window.
zero_nd <- unique(rows$pollutant[rows$is_nd & !is.na(rows$value) & rows$value == 0])
zero_sentence <- if (length(zero_nd)) {
  paste0(" The exception is ", paste(sort(zero_nd), collapse = ", "),
         ", which the field instrument records as zero when none is detected.")
} else ""

# Built from the requirements data: the conditions cited and the frequencies in
# use at this site, most frequent first.
.and <- function(x) if (length(x) < 2) x else
  paste(paste(head(x, -1), collapse = ", "), "and", tail(x, 1))
req_conditions <- local({
  cc <- sort(unique(LICENCE_REQUIREMENTS$condition))
  paste(if (length(cc) > 1) "conditions" else "condition", .and(cc))
})
req_frequencies <- local({
  f <- names(FREQUENCY_COUNT)[names(FREQUENCY_COUNT) %in%
                                LICENCE_REQUIREMENTS$frequency[!is.na(LICENCE_REQUIREMENTS$required)]]
  paste(paste(f, "=", FREQUENCY_COUNT[f]), collapse = ", ")
})

.disch_n <- if (EXTRAS) PT_DISCHARGE else intersect(PT_DISCHARGE, agg$epa_point)
NOTE <- list(
  paste0(
    "Note on values below the analytical detection limit. Where a result was ",
    "below the detection limit for the analysis, the figure shown is that ",
    "detection limit rather than a measured concentration, in accordance with ",
    "the convention stated in the licence Dictionary.", zero_sentence,
    " Such figures are shown in grey italics."
  ),
  paste0(
    "A Lowest or Highest value in grey italics was attained only by ",
    "below-detection results. A Mean in grey italics indicates that every ",
    "result for that monitoring point and pollutant was below detection. ",
    "Figures in normal type are measured values."
  ),
  paste0(
    "No. of samples required is taken from ", req_conditions, " of licence ",
    S$licence, " (", req_frequencies, ")",
    if (EXTRAS) ". It is left blank where the licence sets no requirement for that pollutant at that point",
    if (length(.disch_n)) paste0(
      if (EXTRAS) ", and for " else ". It is left blank for ", name_points(.disch_n), ", where condition ",
      S$special_frequency_condition, " Special Frequency 1 requires sampling ",
      "within the first 24 hours of each discharge rather than a fixed number ",
      "of samples"),
    "."
  ),
  lapply(intersect(PT_GRID, agg$epa_point), function(gp) paste0(
    "At ", name_points(gp), " the number of samples collected counts individual ",
    "grid locations. The ", tolower(grid_frequency(gp)), " requirement refers ",
    "to monitoring events."
  )),
  S$notes  # site-specific notes, e.g. a unit departure from the licence
)
NOTE <- unlist(NOTE)
for (i in seq_along(NOTE)) {
  wb$add_data(x = NOTE[[i]], dims = paste0("A", NOTE_ROW + i - 1L),
              col_names = FALSE)
  wb$add_font(dims = paste0("A", NOTE_ROW + i - 1L),
              italic = "1", color = GREY, name = FONT, size = FSIZE)
}

wb$save(out_path)

hr("WRITTEN")
say(out_path)
say("Template untouched: ", template)
say("")
say("Column 4 \"", headers[[4]], "\" is transcribed from licence conditions")
say("M2.2/M2.3 - it is not in the database. See assumption M for the three")
say("cases that deliberately stay empty.")
say("")
say("Reporting-limit cells marked grey italic (assumption P):")
say(sprintf("  Lowest  %4d of %d", n_marked[["Lowest"]],  nrow(agg)))
say(sprintf("  Mean    %4d of %d   (all results below detection)",
            n_marked[["Mean"]], nrow(agg)))
say(sprintf("  Highest %4d of %d", n_marked[["Highest"]], nrow(agg)))
say("Footnote explaining the convention written at row ", NOTE_ROW, ".")

# Show a couple of EPA points so the result is inspectable from the console.
PEEK_POINTS <- strsplit(TUNABLES$peek %||% S$peek, ",")[[1]]
hr(paste0("SAMPLE OF THE RESULT (EPA point", if (length(PEEK_POINTS) > 1) "s" else "",
          " ", paste(PEEK_POINTS, collapse = ", "), ")"))
peek <- agg[agg$epa_point %in% PEEK_POINTS, , drop = FALSE]
if (nrow(peek)) {
  old_width <- options(width = 200)
  print(data.frame(
    Point      = peek$epa_point,
    Pollutant  = peek$pollutant,
    Unit       = peek$unit_out,
    Required   = peek$required,
    Collected  = peek$n_samples,
    Lowest     = signif(peek$lowest, 6),
    Mean       = signif(peek$mean, 6),
    Highest    = signif(peek$highest, 6),
    check.names = FALSE
  ), row.names = FALSE)
  options(old_width)
} else say("  (no rows at those points in this window)")

# Required (point, pollutant) pairs with NO data in the window have no row in
# the return at all (assumption M), so say so once, loudly.
if (nrow(no_data)) {
  nd_list <- paste0("pt ", no_data$epa_point, " ", no_data$pollutant,
                    " (", no_data$frequency, ")")
  nd_list <- nd_list[order(suppressWarnings(as.numeric(no_data$epa_point)),
                           no_data$pollutant)]
  # message(), not warning(): warning() truncates at 8170 characters and a
  # site with large gaps lists several hundred pairs.
  message(sprintf(paste0(
    "\nWARNING: %d of %d required (point, pollutant) pairs have NO data in %s to %s and ",
    "are absent from the return:\n  %s"),
    nrow(no_data), nrow(req_counted), TUNABLES$window_start, TUNABLES$window_end,
    paste(nd_list, collapse = "\n  ")))
}

invisible(NULL)
