# Apply migration 067 (Robin's rulings on the follow-up detail of the 2026-10-21 triage):
# dry run, migrate, re-run (no-op), with table counts and the open review count before
# and after. A SEPARATE POST-IMPORT STEP: after 066 (marker 1066 is required). Not
# wired into apply-corpus-import.sh. Run from the repo root:
#   Rscript dev/migrations/apply-067-apply-followup-rulings.R
# Set SAMPLETIDY_MIG067_DB / SAMPLETIDY_MIG067_SNAPSHOT_DIR / SAMPLETIDY_MIG067_CSV_DIR
# to point it at a scratch copy (rehearsal); unset, it targets the LIVE db and writes
# the BACKUP and SKIPPED CSVs to dev/migrations/. Groups whose rows changed since the
# plan was frozen are skipped and listed in the SKIPPED CSV.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/067-apply-followup-rulings.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG067_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG067_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG067_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig067_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '067-apply-followup-rulings') AS log_067 FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT kind, count(*) AS open FROM review_queue WHERE status = 'open' GROUP BY 1 ORDER BY 1"))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig067_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# NOT applied to live. Rehearsals (2 fresh post-066 copies, identical results, third
# run already_migrated): scratchpad/2026-10-21-review/m067/r1, r2.
