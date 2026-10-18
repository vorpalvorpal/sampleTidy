# Apply migration 040 to the live DB: dry run, migrate, re-run (no-op), with
# the ES2623357 XTAB's ingest_file row and the ES2623357 sample counts before
# and after. Apply AFTER 039, and before the next ingest of the staged
# ES2623357 folder (that ingest only imports the XTAB once the narrowed
# re-ingest guard has landed in R/). Run from the repo root:
#   Rscript dev/migrations/apply-040-reset-es2623357-xtab.R
# Set SAMPLETIDY_MIG040_DB / SAMPLETIDY_MIG040_SNAPSHOT_DIR /
# SAMPLETIDY_MIG040_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the BACKUP CSV to dev/migrations/.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/040-reset-es2623357-xtab.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG040_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG040_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG040_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM ingest_file) AS ingest_file, (SELECT count(*) FROM asset) AS asset,
    (SELECT count(*) FROM change_log WHERE actor = '040-reset-es2623357-xtab') AS log_040
    FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT filename, state, state_reason, adapter, updated_at
    FROM ingest_file WHERE hash = 'b27ec761bfac521faf6dffa8012048c6'"))
  print(DBI::dbGetQuery(con, "SELECT COALESCE(s.organisation, '(null)') AS organisation, count(*) AS n_sample
    FROM \"sample\" s JOIN project p ON p.uuid = s.uuid_project WHERE p.name = 'ES2623357' GROUP BY 1 ORDER BY 1"))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig040_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
# Rehearsed twice on fresh copies of live at 1039 (scratchpad mig040/): dry
# run clean; migrate -> row archived/retained_sibling -> seen/NULL, change_log
# +2 (state, state_reason; actor 040, source_hash = the XTAB's), marker 1040,
# nothing else moved (asset 1517, ingest_file 86 unchanged); re-run
# already_migrated. Both runs' BACKUP CSVs identical. After 040, the staged
# ES2623357 folder ingested with the R/ of 2026-10-18 (guard NOT yet narrowed)
# is held: row -> needs_review, work_order_reingest/blocked (171 rows), 0
# committed; with the narrowed guard simulated it commits 171 rows / 9 ALS
# samples, reuses asset b56e3eea, row -> archived / commit_event: ES2623357.
# 040's re-run re-verifies clean in all three later states.
report("after")
