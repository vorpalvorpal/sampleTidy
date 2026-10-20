# Apply migration 058 to the live DB: dry run, migrate, re-run (no-op), with
# the 'b.lo2' alias rows before and after. Apply AFTER 057. Run from the repo root:
#   Rscript dev/migrations/apply-058-bound-b-lo2-alias.R
# Set SAMPLETIDY_MIG058_DB / SAMPLETIDY_MIG058_SNAPSHOT_DIR /
# SAMPLETIDY_MIG058_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the BACKUP/INSERTED CSVs to dev/migrations/.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/058-bound-b-lo2-alias.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG058_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG058_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG058_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '058-bound-b-lo2-alias') AS log_058,
    (SELECT count(*) FROM feature_alias) AS n_alias
    FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT fa.uuid, fa.name, f.name AS feature, fa.kind, fa.auto_assign, fa.confirmed_by,
      fa.date_start, fa.date_end FROM feature_alias fa LEFT JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE fa.alias_key = 'b.lo2' ORDER BY fa.date_start NULLS FIRST"), right = FALSE)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig058_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# NOT applied. Rehearsal record: see dev/MIGRATIONS.md (marker 1058).
