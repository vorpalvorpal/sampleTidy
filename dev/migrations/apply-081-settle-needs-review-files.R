# Apply migration 081 (Robin 2026-10-25, "fix"): move the ingest_file rows left in needs_review,
# whose deliveries' review items are all resolved, on to archived. Dry run, migrate, re-run
# (no-op), with table counts and db_checks(tier = "all") before and after. Requires marker
# 1080. Run from the repo root:
#   Rscript dev/migrations/apply-081-settle-needs-review-files.R
# Rehearsal: set SAMPLETIDY_MIG081_DB / _SNAPSHOT_DIR / _CSV_DIR. Unset, it targets the LIVE db.
# No file is read or moved: only ingest_file.state/state_reason/updated_at of the planned rows
# change.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/081-settle-needs-review-files.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG081_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG081_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG081_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
cat("db:", db, "\n")
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig081_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '081-settle-needs-review-files') AS log_081,
    (SELECT count(*) FROM ingest_file WHERE state = 'needs_review') AS needs_review,
    (SELECT count(*) FROM ingest_file WHERE state = 'archived') AS archived
    FROM schema_version"))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig081_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# Applied to live 2026-10-25 00:39 UTC (backup pre-081 ...20261025T003933.837Z).
