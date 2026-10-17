# Apply migration 028 to the live DB: dry run, migrate, re-run (no-op), then
# print counts. Apply AFTER 027. Run from the repo root:
#   Rscript dev/migrations/apply-028.R
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/028-gas-building-features.R", envir = env)
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig028_run(db = st_config("live_db"),
                      snapshot_dir = st_config("snapshot_dir"),
                      dry_run = dr)
  cat("dry_run =", dr, "->", r$status, "\n")
}
con <- DBI::dbConnect(duckdb::duckdb(), st_config("live_db"), read_only = TRUE)
print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
  (SELECT count(*) FROM feature) AS feature,
  (SELECT count(*) FROM feature_alias) AS feature_alias,
  (SELECT count(*) FROM feature WHERE regexp_matches(name, '^K\\.G(379|38[0-9]|39[0-9]|4[0-6][0-9]|47[0-3])$')) AS k_g379_473
  FROM schema_version"))
DBI::dbDisconnect(con, shutdown = TRUE)
