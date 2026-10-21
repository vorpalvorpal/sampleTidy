# Apply migration 065 (the 2026-10-21 review-queue triage, clear verdicts): dry run,
# migrate, re-run (no-op), with table counts and the open review count before and
# after. A SEPARATE POST-IMPORT STEP: after 063/064 (marker 1064 is required). Not
# wired into apply-corpus-import.sh. Run from the repo root:
#   Rscript dev/migrations/apply-065-resolve-review-queue-triage.R
# Set SAMPLETIDY_MIG065_DB / SAMPLETIDY_MIG065_SNAPSHOT_DIR / SAMPLETIDY_MIG065_CSV_DIR
# to point it at a scratch copy (rehearsal); unset, it targets the LIVE db and writes
# the BACKUP and SKIPPED CSVs to dev/migrations/. Groups whose rows changed since the
# frozen copy (2026-10-21 20:59) are skipped and listed in the SKIPPED CSV.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/065-resolve-review-queue-triage.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG065_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG065_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG065_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig065_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '065-resolve-review-queue-triage') AS log_065 FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT kind, count(*) AS open FROM review_queue WHERE status = 'open' GROUP BY 1 ORDER BY 1"))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig065_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# NOT applied. Rehearsal record: see dev/MIGRATIONS.md (marker 1065).
