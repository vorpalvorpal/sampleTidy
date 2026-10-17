# Apply migration 033 to the live DB: dry run, migrate, re-run (no-op), then
# re-verify 021 and 024-032 and print counts. Apply AFTER 032. Run from the
# repo root:
#   Rscript dev/migrations/apply-033.R
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/033-kl01-alias.R", envir = env)
counts_sql <- "SELECT max(version) AS marker,
  (SELECT count(*) FROM analysis) AS analysis,
  (SELECT count(*) FROM \"sample\") AS n_sample,
  (SELECT count(*) FROM feature_alias) AS feature_alias,
  (SELECT count(*) FROM review_queue WHERE status = 'open') AS review_open,
  (SELECT count(*) FROM change_log WHERE actor = '033-kl01-alias') AS log_033
  FROM schema_version"
con <- DBI::dbConnect(duckdb::duckdb(), st_config("live_db"), read_only = TRUE)
cat("before:\n"); print(DBI::dbGetQuery(con, counts_sql))
DBI::dbDisconnect(con, shutdown = TRUE)
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig033_run(db = st_config("live_db"), snapshot_dir = st_config("snapshot_dir"), dry_run = dr)
  cat("dry_run =", dr, "->", r$status, "\n")
}
for (m in c("021-dust-datetime", "024-merge-aug24-water-duplicates", "025-split-legacy-appearance",
            "026-dust-date-start-and-appearance-fixes", "027-dedupe-legacy-field-readings",
            "028-gas-building-features", "029-legacy-field-corrections", "030-precorpus-fixes",
            "031-datetime-day-typos", "032-letter-o-aliases-and-gas-template-slots")) {
  e <- new.env()
  sys.source(sprintf("dev/migrations/%s.R", m), envir = e)
  args <- list(db = st_config("live_db"), snapshot_dir = st_config("snapshot_dir"))
  if (m == "025-split-legacy-appearance") args$plan <- "dev/migrations/025-split-legacy-appearance-PLAN.csv"
  cat(m, "re-verify ->", do.call(get(sprintf("mig%s_run", substr(m, 1, 3)), envir = e), args)$status, "\n")
}
# Rehearsed twice on copies of live at 1032: feature_alias 2283 -> 2284,
# change_log +1, nothing else changes.
con <- DBI::dbConnect(duckdb::duckdb(), st_config("live_db"), read_only = TRUE)
cat("after:\n"); print(DBI::dbGetQuery(con, counts_sql))
DBI::dbDisconnect(con, shutdown = TRUE)
