# Apply migration 052 to the live DB: dry run, migrate, re-run (no-op). Run from
# the repo root:
#   Rscript dev/migrations/apply-052-lab-qc-backfill.R
# Set SAMPLETIDY_MIG052_DB / SAMPLETIDY_MIG052_SNAPSHOT_DIR to point it at a
# scratch copy (rehearsal); unset, it targets the LIVE db. It reads the archived
# QC PDFs from st_config("archive_dir") (hydrating them on OneDrive).
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/052-lab-qc-backfill.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG052_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG052_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
stopifnot(dir.exists(backup_dir))
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig052_run(db = db, snapshot_dir = backup_dir, dry_run = dr)
  cat("dry_run =", dr, "->", r$status, "\n")
}
