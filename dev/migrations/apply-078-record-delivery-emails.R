# Apply migration 078 (Robin 2026-10-25): record the delivery emails of past imports (R-22.E
# backfill: ingest_email rows, ingest_file.message_id, the _email.eml rows -> ignored/
# delivery_email). Dry run, migrate, re-run (no-op), with table counts and
# db_checks(tier = "all") before and after. Requires marker 1077. The migration calls
# ensure_schema() itself after the verified snapshot, so it works whether or not an import
# has run since R-22.E. Run from the repo root:
#   Rscript dev/migrations/apply-078-record-delivery-emails.R
# Set SAMPLETIDY_MIG078_DB / _SNAPSHOT_DIR / _CSV_DIR to point it at a scratch copy
# (rehearsal); unset, it targets the LIVE db and writes the BACKUP and SKIPPED CSVs to
# dev/migrations/. Only email HEADERS are read (the files are on OneDrive Files-On-Demand).
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/078-record-delivery-emails.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG078_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG078_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG078_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
cat("db:", db, "\n")
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig078_counts(con)))
  has <- env$.mig078_has_message_id(con)
  print(DBI::dbGetQuery(con, sprintf("SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '078-record-delivery-emails') AS log_078,
    (SELECT count(*) FROM ingest_file WHERE path_first_seen LIKE '%%/_email.eml' AND state = 'quarantined') AS eml_quarantined,
    %s AS files_with_message_id FROM schema_version",
    if (has) "(SELECT count(*) FROM ingest_file WHERE message_id IS NOT NULL)" else "0")))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig078_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# Applied to live 2026-10-24 23:35 UTC (backup pre-078 ...20261024T233547.229Z).
