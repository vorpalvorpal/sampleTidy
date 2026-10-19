# Apply migration 049 to the live DB: dry run, migrate, re-run (no-op). Run from
# the repo root:
#   Rscript dev/migrations/apply-049-qc-features.R
# Set SAMPLETIDY_MIG049_DB / SAMPLETIDY_MIG049_SNAPSHOT_DIR to point it at a
# scratch copy (rehearsal); unset, it targets the LIVE db.
# REQUIRES SAMPLETIDY_QC_CODES = the Council-only codes CSV beside the vault
# note (51.16 .../attachments/qc-codes.csv); never a file in this repo.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/049-qc-features.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG049_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG049_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
stopifnot(dir.exists(backup_dir))
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig049_run(db = db, snapshot_dir = backup_dir, dry_run = dr)
  cat("dry_run =", dr, "->", r$status, "\n")
}
