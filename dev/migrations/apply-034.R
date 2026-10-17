# Apply migration 034 to the live DB: dry run, migrate, re-run (no-op), then
# re-verify 021 and 024-033 and print counts. Apply AFTER 033. Run from the
# repo root:
#   Rscript dev/migrations/apply-034.R
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/034-gas-slots-again-and-blaxland-epa-masks.R", envir = env)
counts_sql <- "SELECT max(version) AS marker,
  (SELECT count(*) FROM analysis) AS analysis,
  (SELECT count(*) FROM \"sample\") AS n_sample,
  (SELECT count(*) FROM feature_alias) AS feature_alias,
  (SELECT count(*) FROM analyte_mask WHERE variant = 'EPA') AS epa_analyte_mask,
  (SELECT count(*) FROM review_queue WHERE status = 'open') AS review_open,
  (SELECT count(*) FROM change_log WHERE actor = '034-gas-slots-again-and-blaxland-epa-masks') AS log_034
  FROM schema_version"
con <- DBI::dbConnect(duckdb::duckdb(), st_config("live_db"), read_only = TRUE)
cat("before:\n"); print(DBI::dbGetQuery(con, counts_sql))
DBI::dbDisconnect(con, shutdown = TRUE)
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig034_run(db = st_config("live_db"), snapshot_dir = st_config("snapshot_dir"), dry_run = dr)
  cat("dry_run =", dr, "->", r$status, "\n")
}
for (m in c("021-dust-datetime", "024-merge-aug24-water-duplicates", "025-split-legacy-appearance",
            "026-dust-date-start-and-appearance-fixes", "027-dedupe-legacy-field-readings",
            "028-gas-building-features", "029-legacy-field-corrections", "030-precorpus-fixes",
            "031-datetime-day-typos", "032-letter-o-aliases-and-gas-template-slots", "033-kl01-alias")) {
  e <- new.env()
  sys.source(sprintf("dev/migrations/%s.R", m), envir = e)
  args <- list(db = st_config("live_db"), snapshot_dir = st_config("snapshot_dir"))
  if (m == "025-split-legacy-appearance") args$plan <- "dev/migrations/025-split-legacy-appearance-PLAN.csv"
  # tryCatch: one failing re-verify must not hide the others. 021's fixed count
  # of 122 dust samples is already broken on live by the 2026-10-17 import
  # (2 new ES2531465 dust samples with datetime NULL), independently of 034.
  st <- tryCatch(do.call(get(sprintf("mig%s_run", substr(m, 1, 3)), envir = e), args)$status,
                 error = function(err) paste("FAILED:", conditionMessage(err)))
  cat(m, "re-verify ->", st, "\n")
}
# Rehearsed twice on copies of live at 1033 (scratchpad/2026-10-17-mig034/):
# marker 1034, analysis 100209 -> 100205, sample 18788 -> 18784,
# feature_alias 2287 -> 2285, EPA analyte_mask 143 -> 146, open review items
# 37 -> 33, change_log +30; 024-033 re-verify; 021 fails on its fixed count
# both before and after 034 (124 dust samples, expected 122).
con <- DBI::dbConnect(duckdb::duckdb(), st_config("live_db"), read_only = TRUE)
cat("after:\n"); print(DBI::dbGetQuery(con, counts_sql))
DBI::dbDisconnect(con, shutdown = TRUE)
