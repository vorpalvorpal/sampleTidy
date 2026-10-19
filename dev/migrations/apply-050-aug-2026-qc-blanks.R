# Apply migration 050 to the live DB: dry run, migrate, re-run (no-op). Run from
# the repo root:
#   Rscript dev/migrations/apply-050-aug-2026-qc-blanks.R
# Set SAMPLETIDY_MIG050_DB / SAMPLETIDY_MIG050_SNAPSHOT_DIR to point it at a
# scratch copy (rehearsal); unset, it targets the LIVE db. Row backups go to
# dev/migrations/ (050-...-BACKUP-*.csv) when run from the repo root.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/050-aug-2026-qc-blanks.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG050_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG050_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
stopifnot(dir.exists(backup_dir))
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig050_run(db = db, snapshot_dir = backup_dir, dry_run = dr)
  cat("dry_run =", dr, "->", r$status, "\n")
}
