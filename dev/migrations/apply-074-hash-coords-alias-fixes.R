# Apply migration 074 (Robin 2026-10-22): the standing-check findings 073 left open
# (D1 delete the 13 SHA-256-keyed ingest_file rows, D2 placeholder coordinates for
# B.S02 / B.MW05 / B.MW03 from B.centroid, D3 the b.s22 -> B.S06 arm starts
# 2021-03-26). Dry run, migrate, re-run (no-op), with table counts and
# db_checks(tier = "all") before and after. A SEPARATE POST-IMPORT STEP: after 073
# (marker 1073 is required). Not wired into apply-corpus-import.sh. Run from the repo
# root:
#   Rscript dev/migrations/apply-074-hash-coords-alias-fixes.R
# Set SAMPLETIDY_MIG074_DB / SAMPLETIDY_MIG074_SNAPSHOT_DIR / SAMPLETIDY_MIG074_CSV_DIR
# to point it at a scratch copy (rehearsal); unset, it targets the LIVE db and writes
# the BACKUP and SKIPPED CSVs to dev/migrations/. A group whose rows changed since the
# freeze, or whose guard fails, is skipped (listed in the SKIPPED CSV).
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/074-hash-coords-alias-fixes.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG074_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG074_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG074_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig074_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '074-hash-coords-alias-fixes') AS log_074 FROM schema_version"))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig074_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# Rehearsed (not applied): 2 fresh plain-cp copies of live at marker 1073, identical
# results, third run already_migrated; negative checks: scratchpad m074/r1, r2.
