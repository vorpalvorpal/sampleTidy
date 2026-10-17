# Apply migration 027 to the live DB: dry run, migrate, re-run (no-op), then
# print counts. Run from the repo root: Rscript dev/migrations/apply-027.R
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/027-dedupe-legacy-field-readings.R", envir = env)
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig027_run(db = st_config("live_db"),
                      snapshot_dir = st_config("snapshot_dir"),
                      dry_run = dr)
  cat("dry_run =", dr, "->", r$status, "\n")
}
# 025's re-verify skips the B.E01 2023-09-13 pair once 1027 exists; prove it still passes.
e025 <- new.env()
sys.source("dev/migrations/025-split-legacy-appearance.R", envir = e025)
cat("025 re-verify ->", e025$mig025_run(db = st_config("live_db"), snapshot_dir = st_config("snapshot_dir"),
                                       plan = "dev/migrations/025-split-legacy-appearance-PLAN.csv")$status, "\n")
# Rehearsed (twice, on copies of live at 1026): marker 1027, analysis 94995 -> 94979, n_sample 15164 unchanged.
con <- DBI::dbConnect(duckdb::duckdb(), st_config("live_db"), read_only = TRUE)
print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
  (SELECT count(*) FROM analysis) AS analysis,
  (SELECT count(*) FROM \"sample\") AS n_sample FROM schema_version"))
DBI::dbDisconnect(con, shutdown = TRUE)
