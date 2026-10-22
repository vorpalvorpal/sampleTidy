# Apply migration 073 (Robin 2026-10-22, PLAN-22 C): fix what the standing DB checks
# found, where the right value is clear (C1 duplicate analyses, C6 b.s22 alias
# window, C7 B.TS28 start, C8 one sample's date). Dry run, migrate,
# re-run (no-op), with table counts and db_checks(tier = "all") before and after. A
# SEPARATE POST-IMPORT STEP: after 072 (marker 1072 is required). Not wired into
# apply-corpus-import.sh. Run from the repo root:
#   Rscript dev/migrations/apply-073-db-check-fixes.R
# Set SAMPLETIDY_MIG073_DB / SAMPLETIDY_MIG073_SNAPSHOT_DIR / SAMPLETIDY_MIG073_CSV_DIR
# to point it at a scratch copy (rehearsal); unset, it targets the LIVE db and writes
# the BACKUP and SKIPPED CSVs to dev/migrations/. A group whose rows changed since the
# freeze is skipped (listed in the SKIPPED CSV).
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/073-db-check-fixes.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG073_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG073_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG073_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig073_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '073-db-check-fixes') AS log_073 FROM schema_version"))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig073_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# Applied to live 2026-10-22 02:58 UTC (backup pre-073 ...20261022T025819.956Z).
# Rehearsals (2 fresh plain-cp copies of live at marker 1072,
# identical results, third run already_migrated; negative checks): scratchpad m073/r1, r2.
