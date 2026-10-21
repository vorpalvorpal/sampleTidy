# Apply migration 062 to the live DB: dry run, migrate, re-run (no-op), with the
# amended January 2026 report's asset row before and after. Apply AFTER 061 (the
# corpus import script runs it as the step after 061). Run from the repo root:
#   Rscript dev/migrations/apply-062-refile-amended-2400-7538-01.R
# Set SAMPLETIDY_MIG062_DB / SAMPLETIDY_MIG062_SNAPSHOT_DIR /
# SAMPLETIDY_MIG062_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the BACKUP CSV to dev/migrations/.
# No file moves: archived files live at <archive_dir>/<asset uuid>/<filename>.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/062-refile-amended-2400-7538-01.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG062_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG062_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG062_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '062-refile-amended-2400-7538-01') AS log_062
    FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT a.uuid, p.name AS project, a.filename, a.comments FROM asset a
    LEFT JOIN project p ON p.uuid = a.uuid_project
    WHERE a.uuid IN ('6e236970-accb-4e5a-b46a-fc448dec80b4', '4812773b-095c-46a4-bbe6-1fd21c291389')"), right = FALSE)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig062_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# NOT applied. Rehearsal record: see dev/MIGRATIONS.md (marker 1062).
