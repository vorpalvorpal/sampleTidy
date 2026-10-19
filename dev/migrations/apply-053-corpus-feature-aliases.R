# Apply migration 053 to the live DB: dry run, migrate, re-run (no-op), with
# the touched alias keys before and after. Apply AFTER 052, and only once Robin
# has checked 053-corpus-feature-aliases-INPUT.csv. Run from the repo root:
#   Rscript dev/migrations/apply-053-corpus-feature-aliases.R
# Set SAMPLETIDY_MIG053_DB / SAMPLETIDY_MIG053_SNAPSHOT_DIR /
# SAMPLETIDY_MIG053_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the BACKUP/INSERTED CSVs to dev/migrations/.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/053-corpus-feature-aliases.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG053_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG053_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG053_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '053-corpus-feature-aliases') AS log_053,
    (SELECT count(*) FROM feature_alias) AS n_alias
    FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT fa.name, f.name AS feature, fa.kind, fa.auto_assign, fa.confirmed_by,
      fa.date_start, fa.date_end FROM feature_alias fa LEFT JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE fa.alias_key IN ('lined leachate dam', 's3', 'bore 8', 'b.mw01', 'b.mw02', 'b.mw03', 'b.mw04')
    ORDER BY fa.alias_key, fa.date_start NULLS FIRST, f.name"), right = FALSE)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig053_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# NOT applied. Rehearsal record: see dev/MIGRATIONS.md (marker 1053).
