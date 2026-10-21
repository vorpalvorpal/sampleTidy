# Apply migration 071 (Robin 2026-10-22: keep both fractions; TDS keep both, prefer
# measured EA015): insert the 60 analyses R-8.6 dropped. Dry run, migrate, re-run
# (no-op), with table counts and the open review count before and after. A SEPARATE
# POST-IMPORT STEP: after 070 (marker 1070 is required). Not wired into
# apply-corpus-import.sh. Run from the repo root:
#   Rscript dev/migrations/apply-071-backfill-dropped-fractions.R
# Set SAMPLETIDY_MIG071_DB / SAMPLETIDY_MIG071_SNAPSHOT_DIR / SAMPLETIDY_MIG071_CSV_DIR
# to point it at a scratch copy (rehearsal); unset, it targets the LIVE db and writes
# the BACKUP and SKIPPED CSVs to dev/migrations/. A target sample or kept sibling that
# changed since the freeze skips its sample group (listed in the SKIPPED CSV).
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/071-backfill-dropped-fractions.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG071_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG071_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG071_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig071_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '071-backfill-dropped-fractions') AS log_071 FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT kind, count(*) AS open FROM review_queue WHERE status = 'open' GROUP BY 1 ORDER BY 1"))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig071_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# NOT applied to live. Rehearsals (2 fresh plain-cp copies of post-070 live, identical
# results, third run already_migrated): scratchpad/2026-10-21-review/m071/r1, r2.
