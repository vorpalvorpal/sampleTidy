# Apply migration 080 (Robin 2026-10-25): re-file the two amended ACIRL reports under their
# original reports and delete the two empty "Amended 01" shell projects. Dry run, migrate,
# re-run (no-op), with table counts and db_checks(tier = "all") before and after. Requires
# marker 1079. Run from the repo root:
#   Rscript dev/migrations/apply-080-refile-amended-reports.R
# Rehearsal: set SAMPLETIDY_MIG080_DB / _SNAPSHOT_DIR / _CSV_DIR. Unset, it targets the LIVE db.
# No file is read or moved: only asset.uuid_project/comments, two ingest_file states and two
# project rows change.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/080-refile-amended-reports.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG080_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG080_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG080_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
cat("db:", db, "\n")
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig080_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '080-refile-amended-reports') AS log_080,
    (SELECT count(*) FROM ingest_file WHERE state = 'needs_review') AS needs_review,
    (SELECT count(*) FROM project WHERE name LIKE '% Amended 01') AS amended_shells
    FROM schema_version"))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig080_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# Applied to live 2026-10-25 00:16 UTC (backup pre-080 ...20261025T001627.909Z).
