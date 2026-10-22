# Apply migration 072 (Robin 2026-10-22: remove the EPA views from sampleTidy): drop
# v_analyte_epa, v_feature_epa, v_measurement_epa. Dry run, migrate, re-run (no-op),
# with table counts, the view list and the open review count before and after. A
# SEPARATE POST-IMPORT STEP: after 071 (marker 1071 is required). Not wired into
# apply-corpus-import.sh. Run from the repo root:
#   Rscript dev/migrations/apply-072-drop-epa-views.R
# Set SAMPLETIDY_MIG072_DB / SAMPLETIDY_MIG072_SNAPSHOT_DIR / SAMPLETIDY_MIG072_CSV_DIR
# to point it at a scratch copy (rehearsal); unset, it targets the LIVE db and writes
# the BACKUP CSV to dev/migrations/. A view definition that changed since the freeze
# (sha1), or another view that references one of the three, refuses the whole run.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/072-drop-epa-views.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG072_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG072_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG072_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig072_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '072-drop-epa-views') AS log_072 FROM schema_version"))
  cat("views:", paste(env$.mig072_view_defs(con)$view_name, collapse = ", "), "\n")
  print(DBI::dbGetQuery(con, "SELECT kind, count(*) AS open FROM review_queue WHERE status = 'open' GROUP BY 1 ORDER BY 1"))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig072_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# NOT applied to live. Rehearsals (2 fresh plain-cp copies of live at marker 1071,
# identical results, third run already_migrated; negative checks refuse cleanly):
# scratchpad m072/r1, r2 of session 8ce9e172 (deleted after recording).
