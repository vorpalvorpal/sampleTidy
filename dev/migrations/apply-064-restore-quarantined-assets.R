# Apply migration 064 to the live DB: dry run, migrate, re-run (no-op). Run AFTER
# the historical corpus import (dev/corpus-import/apply-corpus-import.sh live) and
# after a PASS from dev/migrations/064-restore-quarantined-assets-CHECK.R. Run from
# the repo root:
#   Rscript dev/migrations/apply-064-restore-quarantined-assets.R
# Unset, it targets the LIVE db, archive_dir = SAMPLETIDY_ARCHIVE_DIR from
# ~/.Renviron (Sharepoint assets/processed), quarantine =
# assets/_dedupe_quarantine/20261020/processed, and writes the BACKUP CSV to
# dev/migrations/. For a rehearsal set SAMPLETIDY_MIG064_DB, _SNAPSHOT_DIR, _CSV_DIR,
# _ARCHIVE_DIR and _QUARANTINE_DIR to scratch copies.
live_archive <- Sys.getenv("SAMPLETIDY_ARCHIVE_DIR")   # read before load_all (test helpers isolate config)
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/064-restore-quarantined-assets.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG064_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG064_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG064_CSV_DIR", unset = "dev/migrations")
archive_dir <- Sys.getenv("SAMPLETIDY_MIG064_ARCHIVE_DIR", unset = live_archive)
quarantine_dir <- Sys.getenv("SAMPLETIDY_MIG064_QUARANTINE_DIR", unset = env$.mig064_default_quarantine(archive_dir))
stopifnot(nzchar(archive_dir), dir.exists(archive_dir), dir.exists(backup_dir), dir.exists(csv_dir))
cat("db:", db, "\narchive_dir:", archive_dir, "\nquarantine:", quarantine_dir, "\n")
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker, (SELECT count(*) FROM asset) AS assets,
    (SELECT count(*) FROM change_log WHERE actor = '064-restore-quarantined-assets') AS log_064
    FROM schema_version"))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig064_run(db = db, snapshot_dir = backup_dir, archive_dir = archive_dir,
                      quarantine_dir = quarantine_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# NOT applied. Rehearsal record: see dev/MIGRATIONS.md (marker 1064).
