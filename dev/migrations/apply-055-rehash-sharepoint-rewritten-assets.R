# Apply migration 055 to the live DB: dry run, migrate, re-run (no-op), with the
# re-hashed asset rows before and after. Apply
# AFTER 054. Run from the repo root:
#   Rscript dev/migrations/apply-055-rehash-sharepoint-rewritten-assets.R
# Set SAMPLETIDY_MIG055_DB / SAMPLETIDY_MIG055_SNAPSHOT_DIR /
# SAMPLETIDY_MIG055_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the BACKUP CSV to dev/migrations/.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/055-rehash-sharepoint-rewritten-assets.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG055_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG055_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG055_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":
")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '055-rehash-sharepoint-rewritten-assets') AS log_055,
    (SELECT count(*) FROM asset) AS assets
    FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT uuid, hash, left(filename, 40) AS filename FROM asset WHERE comments LIKE '%055: hash was%' ORDER BY filename"), right = FALSE)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig055_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# Rehearsed twice on copies of live at 1052+053+054; NOT applied (see dev/MIGRATIONS.md).
