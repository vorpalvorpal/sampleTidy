# Apply migration 083 (Robin 2026-10-26): move the December 2025 Blaxland quarterly field
# sheet "Quarterly 2-12.pdf" from ES2623357 to its work order ES2538342. Dry run, migrate,
# re-run (no-op), with table counts and db_checks(tier = "all") before and after. Requires
# marker 1082. Run from the repo root:
#   Rscript dev/migrations/apply-083-refile-blaxland-dec-2025-field-sheet.R
# Rehearsal: set SAMPLETIDY_MIG083_DB / _SNAPSHOT_DIR / _CSV_DIR. Unset, it targets the LIVE db.
# No file is read or moved: only asset.uuid_project/comments of one row change.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/083-refile-blaxland-dec-2025-field-sheet.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG083_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG083_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG083_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
cat("db:", db, "\n")
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig083_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '083-refile-blaxland-dec-2025-field-sheet') AS log_083,
    (SELECT p.name FROM asset a JOIN project p ON p.uuid = a.uuid_project
       WHERE a.uuid = '2c5acb02-423f-408c-9500-57fb5570148b') AS asset_project
    FROM schema_version"))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig083_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
