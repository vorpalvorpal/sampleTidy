# Apply migration 054 to the live DB: dry run, migrate, re-run (no-op), with the
# three ignored files' ingest_file rows and project ES2006927 before and after. Apply AFTER 053. Run from
# the repo root:
#   Rscript dev/migrations/apply-054-hold-2400-7400-07.R
# Set SAMPLETIDY_MIG054_DB / SAMPLETIDY_MIG054_SNAPSHOT_DIR /
# SAMPLETIDY_MIG054_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the BACKUP CSV to dev/migrations/.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/054-hold-2400-7400-07.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG054_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG054_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG054_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '054-hold-2400-7400-07') AS log_054
    FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT hash, filename, state, state_reason, adapter, tier FROM ingest_file
    WHERE hash IN ('07bcecfc6312255ae6f21cc6c977daaa',
    'e11b438cfd496070dc2fef28effdbbe3', 'b66193946f485819e4b0e1451f1e70ac')"), right = FALSE)
  print(DBI::dbGetQuery(con, "SELECT name, comments FROM project
    WHERE uuid = '2b34a4fb-1cca-4ba5-b7b4-98205bcc70e6'"), right = FALSE)
  print(DBI::dbGetQuery(con, "SELECT datetime, comments FROM sample
    WHERE uuid_project = '2b34a4fb-1cca-4ba5-b7b4-98205bcc70e6'"), right = FALSE)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig054_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# NOT applied. Rehearsal record: see dev/MIGRATIONS.md (marker 1054).
