# Apply migration 076 (Robin 2026-10-25): remove the derived msPAF measure (analyte AmsPAF,
# lab_method 'Computed: Adjusted msPAF', its 903 analyses, 4 guideline rows, 1 analyte_mask
# row) from the measurement DB. Dry run, migrate, re-run (no-op), with table counts and
# db_checks(tier = "all") before and after. A SEPARATE POST-IMPORT STEP: after 074 (marker
# 1074 is required; 075 is independent). Not wired into apply-corpus-import.sh. Run from the
# repo root:
#   Rscript dev/migrations/apply-076-remove-derived-mspaf.R
# Set SAMPLETIDY_MIG076_DB / SAMPLETIDY_MIG076_SNAPSHOT_DIR / SAMPLETIDY_MIG076_CSV_DIR
# to point it at a scratch copy (rehearsal); unset, it targets the LIVE db and writes
# the BACKUP and SKIPPED CSVs to dev/migrations/. If any guard fails the whole migration is
# skipped (listed in the SKIPPED CSV) and nothing is written.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/076-remove-derived-mspaf.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG076_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG076_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG076_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig076_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '076-remove-derived-mspaf') AS log_076,
    (SELECT count(*) FROM v_measurement WHERE analyte_name = 'AmsPAF') AS v_measurement_mspaf FROM schema_version"))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig076_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# Applied to live 2026-10-24 22:45 UTC (backup pre-076 ...20261024T224548.780Z).
