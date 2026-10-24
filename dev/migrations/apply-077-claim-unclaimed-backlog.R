# Apply migration 077 (Robin 2026-10-25): claim the unclaimed-file backlog under the current
# importer's retention rules (R-22.G1 / R-22.G2; prelims superseded by their final are
# ignored). Dry run, migrate, re-run (no-op), with table counts and db_checks(tier = "all")
# before and after. Requires marker 1076. Run from the repo root:
#   Rscript dev/migrations/apply-077-claim-unclaimed-backlog.R
# Rehearsal: set SAMPLETIDY_MIG077_DB / _SNAPSHOT_DIR / _CSV_DIR AND SAMPLETIDY_MIG077_ARCHIVE_DIR
# (a scratch directory: archive_file() copies the retained files to <archive_dir>/<uuid>/). With
# _DB set, an unset or OneDrive _ARCHIVE_DIR is refused, so a rehearsal can never write into the
# real processed/ tree. Unset, it targets the LIVE db and st_config("archive_dir").
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/077-claim-unclaimed-backlog.R", envir = env)
rehearsal <- nzchar(Sys.getenv("SAMPLETIDY_MIG077_DB"))
db <- Sys.getenv("SAMPLETIDY_MIG077_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG077_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG077_CSV_DIR", unset = "dev/migrations")
archive_dir <- Sys.getenv("SAMPLETIDY_MIG077_ARCHIVE_DIR", unset = if (rehearsal) "" else st_config("archive_dir"))
if (rehearsal && (!nzchar(archive_dir) || grepl("CloudStorage|OneDrive", archive_dir)))
  stop("rehearsal: SAMPLETIDY_MIG077_ARCHIVE_DIR must be set to a scratch dir outside OneDrive")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir), dir.exists(archive_dir))
cat("db:", db, "\narchive_dir:", archive_dir, "\n")
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig077_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '077-claim-unclaimed-backlog') AS log_077,
    (SELECT count(*) FROM ingest_file WHERE state = 'quarantined' AND state_reason = 'unclaimed') AS unclaimed
    FROM schema_version"))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig077_run(db = db, snapshot_dir = backup_dir, archive_dir = archive_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
