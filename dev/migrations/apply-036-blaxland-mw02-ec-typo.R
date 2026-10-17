# Apply migration 036 to the live DB: dry run, migrate, re-run (no-op), with
# the B.MW02 EC readings for 2026-01-05 before and after. Apply AFTER 035. Run
# from the repo root:
#   Rscript dev/migrations/apply-036-blaxland-mw02-ec-typo.R
# Set SAMPLETIDY_MIG036_DB / SAMPLETIDY_MIG036_SNAPSHOT_DIR to point it at a
# scratch copy (rehearsal); unset, it targets the LIVE db.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/036-blaxland-mw02-ec-typo.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG036_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG036_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
stopifnot(dir.exists(backup_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM analysis) AS analysis,
    (SELECT count(*) FROM change_log WHERE actor = '036-blaxland-mw02-ec-typo') AS log_036
    FROM schema_version"))
  print(env$.mig036_candidates(con)[, c("uuid", "value", "method", "organisation")])
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig036_run(db = db, snapshot_dir = backup_dir, dry_run = dr)
  cat("dry_run =", dr, "->", r$status, "\n")
}
# Rehearsed twice on fresh copies of live at 1035 (scratchpad mig036/):
# marker 1036, analysis count unchanged, change_log +1, field EC 130 -> 1300.
report("after")
