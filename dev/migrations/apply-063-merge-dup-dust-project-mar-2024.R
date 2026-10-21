# Apply migration 063 (DRAFT, AWAITING ROBIN - do not run against live until he
# confirms): dry run, migrate, re-run (no-op), with the Mar-2024 dust projects'
# asset rows before and after. Apply AFTER 062 (the corpus import chain); it is
# NOT wired into dev/corpus-import/apply-corpus-import.sh. Run from the repo root:
#   Rscript dev/migrations/apply-063-merge-dup-dust-project-mar-2024.R
# Set SAMPLETIDY_MIG063_DB / SAMPLETIDY_MIG063_SNAPSHOT_DIR /
# SAMPLETIDY_MIG063_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the BACKUP CSVs to dev/migrations/.
# No file moves: archived files live at <archive_dir>/<asset uuid>/<filename>.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/063-merge-dup-dust-project-mar-2024.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG063_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG063_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG063_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '063-merge-dup-dust-project-mar-2024') AS log_063
    FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT a.uuid, a.uuid_project, a.hash, a.filename FROM asset a
    WHERE a.hash IN ('5998a79383ebfd2b6727d9792b6b022b', '5655aa4002922c7620d50ed1c3d2a88f', '800b663f337223a9a541ea98e7e0ad79')
    ORDER BY a.uuid"), right = FALSE)
  print(DBI::dbGetQuery(con, "SELECT uuid, (SELECT count(*) FROM sample s WHERE s.uuid_project = p.uuid) AS samples
    FROM project p WHERE uuid IN ('ff6f23db-4676-48e1-a253-162c316e22db', 'c7b61e56-aacb-4a37-a296-828ead07566e')"))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig063_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# DRAFT, awaiting Robin; NOT applied. Rehearsal record: see dev/MIGRATIONS.md (marker 1063).
