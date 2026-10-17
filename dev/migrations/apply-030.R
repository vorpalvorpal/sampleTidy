# Apply migration 030 to the live DB: dry run, migrate, re-run (no-op), then
# re-verify 021 and 024-029 and print counts. Apply AFTER 029. Run from the
# repo root:
#   Rscript dev/migrations/apply-030.R
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/030-precorpus-fixes.R", envir = env)
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig030_run(db = st_config("live_db"),
                      snapshot_dir = st_config("snapshot_dir"),
                      dry_run = dr)
  cat("dry_run =", dr, "->", r$status, "\n")
}
# 030 drops and re-creates ux_sample_identity and moves 4 sample datetimes;
# prove the earlier migrations' re-verifies still pass (they did on both
# rehearsals, unchanged).
for (m in c("021-dust-datetime", "024-merge-aug24-water-duplicates", "025-split-legacy-appearance",
            "026-dust-date-start-and-appearance-fixes", "027-dedupe-legacy-field-readings",
            "028-gas-building-features", "029-legacy-field-corrections")) {
  e <- new.env()
  sys.source(sprintf("dev/migrations/%s.R", m), envir = e)
  args <- list(db = st_config("live_db"), snapshot_dir = st_config("snapshot_dir"))
  if (m == "025-split-legacy-appearance") args$plan <- "dev/migrations/025-split-legacy-appearance-PLAN.csv"
  cat(m, "re-verify ->", do.call(get(sprintf("mig%s_run", substr(m, 1, 3)), envir = e), args)$status, "\n")
}
# Rehearsed (twice, on copies of live at 1029 + the gas import): marker 1030,
# analysis 97707, n_sample 17892 and feature_alias 2277 unchanged, change_log
# +9 (8 sample fields, 1 alias field).
con <- DBI::dbConnect(duckdb::duckdb(), st_config("live_db"), read_only = TRUE)
print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
  (SELECT count(*) FROM analysis) AS analysis,
  (SELECT count(*) FROM \"sample\") AS n_sample,
  (SELECT count(*) FROM feature_alias) AS feature_alias,
  (SELECT count(*) FROM change_log WHERE actor = '030-precorpus-fixes') AS log_030
  FROM schema_version"))
DBI::dbDisconnect(con, shutdown = TRUE)
