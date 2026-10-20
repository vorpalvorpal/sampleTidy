# Apply migration 061 to the live DB: dry run, migrate, re-run (no-op), with the
# asset / reference counts before and after. Apply AFTER 059. Run from the repo root:
#   Rscript dev/migrations/apply-061-resolve-ask-robin-assets.R
# Set SAMPLETIDY_MIG061_DB / SAMPLETIDY_MIG061_SNAPSHOT_DIR /
# SAMPLETIDY_MIG061_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the BACKUP CSVs to dev/migrations/.
# Afterwards (files): the 3 deleted 0-byte rows' archive files are quarantined by
#   Rscript dev/processed-dedupe.R --post-import --db <db> --root <assets> --mirror <src> \
#     --merged dev/migrations/057-merge-duplicate-hash-assets-INPUT.csv,dev/migrations/061-resolve-ask-robin-assets-INPUT.csv \
#     --plan-out <work>/post-import-plan.csv
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/061-resolve-ask-robin-assets.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG061_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG061_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG061_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '061-resolve-ask-robin-assets') AS log_061,
    (SELECT count(*) FROM asset) AS assets,
    (SELECT count(*) FROM (SELECT hash FROM asset GROUP BY hash HAVING count(*) > 1)) AS dup_hash_groups,
    (SELECT count(*) FROM lab_qc_report) AS qc_reports,
    (SELECT count(*) FROM lab_qc_outlier) AS qc_outliers
    FROM schema_version"))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig061_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# Rehearsed twice on fresh chains (P0 + 053..059 apply scripts); NOT applied (see dev/MIGRATIONS.md).
