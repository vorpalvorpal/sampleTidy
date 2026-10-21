# Test isolation (2026-10-20). On the writer Mac, ~/.Renviron points
# SAMPLETIDY_ARCHIVE_DIR / _SNAPSHOT_DIR / _INPUT_DIR at the real OneDrive
# tree, and st_config() falls back to those env vars. A test that reaches
# archive_file() or snapshot_db() without its own override then writes into
# the live archive: four empty asset directories appeared in Sharepoint
# processed/ this way on 2026-10-20 from an in-progress test file. Redirect
# any such env var that names a OneDrive path to a per-session temp dir, so
# no test can touch OneDrive. Tests that set their own option or env var are
# unaffected (options win over env vars, and withr::local_envvar() still
# overrides). Where the env vars are unset (CI), nothing changes.
# Only under testthat (TESTTHAT=true): devtools::load_all() also sources
# helpers, and the live scripts (auto-import, corpus import, migrations) load
# the package that way, so outside a test run this must do nothing - it once
# pointed the live corpus import's archive at a temp dir (2026-10-21).
if (identical(Sys.getenv("TESTTHAT"), "true")) local({
  root <- file.path(tempdir(), "sampletidy-test-isolation")
  for (key in c("ARCHIVE_DIR", "SNAPSHOT_DIR", "INPUT_DIR")) {
    var <- paste0("SAMPLETIDY_", key)
    val <- Sys.getenv(var, unset = "")
    if (nzchar(val) && grepl("CloudStorage|OneDrive", val)) {
      dest <- file.path(root, tolower(key))
      dir.create(dest, recursive = TRUE, showWarnings = FALSE)
      do.call(Sys.setenv, stats::setNames(list(dest), var))
    }
  }
})
