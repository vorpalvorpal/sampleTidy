# Deployment settings (stage 1 of the layer move): the zone, the date
# overrides file and the gas site keywords come from the environment of the
# machine that runs the suite (Robin's .Renviron sets the first two). Unset
# them so the suite sees the package defaults, then pin the options the
# existing suites were written against. A test of the defaults clears the
# options itself, with withr::local_options(sampletidy.timezone = NULL).
#
# A setup file, not a helper: devtools::load_all() also sources helpers (the
# live scripts load the package that way), and testthat runs setup files only
# inside a test run, so this can never reach a live import.
Sys.unsetenv(c("SAMPLETIDY_TIMEZONE", "SAMPLETIDY_DATE_OVERRIDES",
               "SAMPLETIDY_SITE_KEYWORDS"))
options(sampletidy.timezone = "Australia/Sydney",
        sampletidy.site_keywords = list(B = "northvale", K = "millbrook"))
