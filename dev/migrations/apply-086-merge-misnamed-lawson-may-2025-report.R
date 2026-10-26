# Apply migration 086 (Robin 2026-10-26): merge the misnamed "2400-7430-01 (2025)" into
# 2400-7483-01 (May 2025 Lawson): ES2515829 and the first-issue workbook move, 2400-7483-01 goes
# under Post-closure monitoring, the empty duplicate is deleted. Dry run, migrate, re-run (no-op),
# with table counts and db_checks(tier = "all") before and after. Requires marker 1084.
# Run from the repo root:
#   Rscript dev/migrations/apply-086-merge-misnamed-lawson-may-2025-report.R
# Rehearsal: set SAMPLETIDY_MIG086_DB / _SNAPSHOT_DIR / _CSV_DIR. Unset, it targets the LIVE db.
# SAMPLETIDY_MIG086_NO_SNAPSHOT=1 (rehearsal only) skips the whole-file snapshot so a rehearsal
# does not put a third DB copy on disk. No file is read or moved.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/086-merge-misnamed-lawson-may-2025-report.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG086_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG086_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG086_CSV_DIR", unset = "dev/migrations")
if (nzchar(Sys.getenv("SAMPLETIDY_MIG086_NO_SNAPSHOT"))) {
  stopifnot(!identical(normalizePath(db), normalizePath(st_config("live_db"))))
  env$mig086_backup <- function(db, snapshot_dir, .now = NULL) {
    with_db_write(function(con) DBI::dbExecute(con, "CHECKPOINT"), db = db)
    "(rehearsal: no snapshot)"
  }
}
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
cat("db:", db, "\n")
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig086_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '086-merge-misnamed-lawson-may-2025-report') AS log_086 FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT p.name, p.type, par.name AS parent,
      (SELECT count(*) FROM project c WHERE c.uuid_parent = p.uuid) AS children,
      (SELECT count(*) FROM sample s WHERE s.uuid_project = p.uuid) AS samples,
      (SELECT count(*) FROM asset a WHERE a.uuid_project = p.uuid) AS assets
    FROM project p LEFT JOIN project par ON par.uuid = p.uuid_parent
    WHERE p.name IN ('2400-7430-01', '2400-7430-01 (2025)', '2400-7483-01', 'ES2515829', 'ES2417748') ORDER BY p.name"))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig086_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
