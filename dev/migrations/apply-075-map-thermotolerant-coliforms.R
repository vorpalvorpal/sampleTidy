# Apply migration 075 (Robin 2026-10-25): map ALS "Thermotolerant Coliforms" (MW006) to the
# Faecal Coliforms analyte, convert its 3 ES2631587 analyses CFU/100mL -> CFU/mL, and close
# review item ae4491dc. Dry run, migrate, re-run (no-op), with table counts and
# db_checks(tier = "all") before and after. A SEPARATE POST-IMPORT STEP: after 074
# (marker 1074 is required). Not wired into apply-corpus-import.sh. Run from the repo root:
#   Rscript dev/migrations/apply-075-map-thermotolerant-coliforms.R
# Set SAMPLETIDY_MIG075_DB / SAMPLETIDY_MIG075_SNAPSHOT_DIR / SAMPLETIDY_MIG075_CSV_DIR
# to point it at a scratch copy (rehearsal); unset, it targets the LIVE db and writes
# the BACKUP and SKIPPED CSVs to dev/migrations/. If a precondition fails the whole group
# is skipped (listed in the SKIPPED CSV).
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/075-map-thermotolerant-coliforms.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG075_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG075_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG075_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig075_counts(con)))
  print(DBI::dbGetQuery(con, sprintf("SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '%s') AS log_075 FROM schema_version", env$.mig075_actor)))
  print(DBI::dbGetQuery(con, sprintf("SELECT lm.uuid_analyte, lm.conversion_constant, lm.units, a.value, a.rl_low
    FROM lab_method lm LEFT JOIN analysis a ON a.uuid_lab = lm.uuid WHERE lm.uuid = '%s' ORDER BY a.uuid", env$.mig075_lm)))
  print(DBI::dbGetQuery(con, sprintf("SELECT status, resolved_by FROM review_queue WHERE uuid = '%s'", env$.mig075_review)))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig075_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
