# Apply migration 056 to the live DB: dry run, migrate, re-run (no-op), with the
# touched rows' counts before and after. Apply AFTER 053-055. Run from the repo
# root:
#   Rscript dev/migrations/apply-056-corpus-live-corrections.R
# Set SAMPLETIDY_MIG056_DB / SAMPLETIDY_MIG056_SNAPSHOT_DIR /
# SAMPLETIDY_MIG056_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the BACKUP CSVs to dev/migrations/.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/056-corpus-live-corrections.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG056_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG056_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG056_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '056-corpus-live-corrections') AS log_056,
    (SELECT count(*) FROM project WHERE name IN ('ES2420251', 'ES2421689')) AS projects,
    (SELECT count(*) FROM \"sample\" s JOIN project p ON p.uuid = s.uuid_project WHERE p.name = 'ES2421689') AS s_21689,
    (SELECT count(*) FROM \"sample\" s JOIN project p ON p.uuid = s.uuid_project WHERE p.name = 'ES2420251') AS s_20251,
    (SELECT count(*) FROM lab_method WHERE organisation = 'ALS' AND name IN ('Decachlorobiphenyl', 'Naphthalene (Ex SVOC)')) AS d13
    FROM schema_version"))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig056_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# NOT applied. Rehearsal record: see dev/MIGRATIONS.md (marker 1056).
