# Apply migration 059 to the live DB: dry run, migrate, re-run (no-op), with the
# 2400-7453-03-01 report projects before and after. Apply AFTER 058. Run from the repo root:
#   Rscript dev/migrations/apply-059-split-reused-report-numbers.R
# Set SAMPLETIDY_MIG059_DB / SAMPLETIDY_MIG059_SNAPSHOT_DIR /
# SAMPLETIDY_MIG059_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the BACKUP CSVs to dev/migrations/.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/059-split-reused-report-numbers.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG059_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG059_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG059_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT (SELECT max(version) FROM schema_version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '059-split-reused-report-numbers') AS log_059,
    p.name, p.type, count(s.uuid) AS samples, min(cast(coalesce(s.date, s.datetime) + interval 11 hour as date)) AS first,
    max(cast(coalesce(s.date, s.datetime) + interval 11 hour as date)) AS last
    FROM project p LEFT JOIN \"sample\" s ON s.uuid_project = p.uuid
    WHERE p.name = '2400-7453-03-01' OR p.name LIKE '2400-7453-03-01 (%' GROUP BY ALL ORDER BY p.name"))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig059_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
