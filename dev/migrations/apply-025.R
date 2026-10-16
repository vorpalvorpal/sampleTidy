# Apply migration 025 to the live DB: dry run, migrate, re-run (no-op), then
# print counts. Run from the repo root: Rscript dev/migrations/apply-025.R
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/025-split-legacy-appearance.R", envir = env)
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig025_run(db = st_config("live_db"),
                      snapshot_dir = st_config("snapshot_dir"),
                      dry_run = dr)
  cat("dry_run =", dr, "->", r$status, "\n")
}
con <- DBI::dbConnect(duckdb::duckdb(), st_config("live_db"), read_only = TRUE)
print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
  (SELECT count(*) FROM analysis) AS analysis,
  (SELECT count(*) FROM sample) AS sample FROM schema_version"))
DBI::dbDisconnect(con, shutdown = TRUE)
