# Deployment settings (stages 1-3 of the layer move): the zone, the date
# overrides file, the gas site keywords, the report and input directories come
# from the environment of the machine that runs the suite (a writer machine's
# .Renviron sets several). Unset them so the suite sees the package defaults,
# then pin the options the existing suites were written against (the gas
# slots, the ACIRL job prefix, the field-analytes allowlist). A test of the
# defaults clears the options itself, with withr::local_options(sampletidy.timezone = NULL).
#
# Isolation (mandatory): R reads R_ENVIRON_USER (else ~/.Renviron) at start-up
# and that file BEATS exported variables, so an R or bash child that a test
# starts would otherwise see the live deployment's keys (the live DB, the
# vault's report dir). Point R_ENVIRON_USER at an empty temp file for the whole
# session; a test that needs keys writes its own file and sets the variable.
#
# The inbox recogniser is no longer pinned here: inbox_setup() sets
# test_batches() for the calling test (helper-inbox.R).
#
# A setup file, not a helper: devtools::load_all() also sources helpers (the
# live scripts load the package that way), and testthat runs setup files only
# inside a test run, so this can never reach a live import.
Sys.unsetenv(c("SAMPLETIDY_TIMEZONE", "SAMPLETIDY_DATE_OVERRIDES",
               "SAMPLETIDY_SITE_KEYWORDS", "SAMPLETIDY_REPORT_DIR",
               "SAMPLETIDY_INPUT_DIR", "SAMPLETIDY_ACIRL_JOB_PREFIX"))
local({
  empty_environ <- tempfile("empty-renviron-")
  file.create(empty_environ)
  Sys.setenv(R_ENVIRON_USER = empty_environ)
  withr::defer(unlink(empty_environ), testthat::teardown_env())
})
options(sampletidy.timezone = "Australia/Sydney",
        sampletidy.site_keywords = list(N = "northvale", M = "millbrook"),
        sampletidy.gas_template_slots = c("N.G201", "M.G365", "M.G366"),
        sampletidy.acirl_job_prefix = "2400",
        sampletidy.field_analytes = c(
          "pH", "Temperature", "Electrical Conductivity",
          "Standing Water Level", "Standing Water Height", "Standing water level",
          "Water Height", "Water Depth",
          "DO", "ORP", "CH4 Reading % v/v", "H2S Reading % v/v",
          "O2 Reading % v/v", "CO2 Reading % v/v",
          "Turbidity", "Conductivity", "EC"))
