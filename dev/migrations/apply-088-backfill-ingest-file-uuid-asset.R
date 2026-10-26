# Apply migration 088 (Robin 2026-10-26, archive-settle design): backfill ingest_file.uuid_asset.
# Dry run, migrate, re-run (no-op), with table counts and db_checks before and after.
# Requires marker 1087. Run from the repo root:
#   Rscript dev/migrations/apply-088-backfill-ingest-file-uuid-asset.R
# Rehearsal: set SAMPLETIDY_MIG088_DB / _SNAPSHOT_DIR / _CSV_DIR. Unset, it targets the LIVE db.
# Freeze (once, read-only; writes the INPUT): SAMPLETIDY_MIG088_FREEZE=1.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/088-backfill-ingest-file-uuid-asset.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG088_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG088_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG088_CSV_DIR", unset = "dev/migrations")
cat("db:", db, "\n")
if (nzchar(Sys.getenv("SAMPLETIDY_MIG088_FREEZE"))) {
  p <- env$mig088_freeze(db, archive_dir = st_config("archive_dir"))
  cat(sprintf("Froze %d row(s) from %d NULL-link ingest_file rows (%d with no asset left alone; %d already linked):\n",
              nrow(p$input), p$n_null, p$n_unlinkable, p$already_linked))
  print(table(p$input$action, p$input$source))
  print(p$input[p$input$action == "skip", c("hash", "source", "note")], right = FALSE)
  quit(save = "no")
}
# Rehearsal only: skip the whole-file snapshot (checkpoint only). Never set it for live.
if (nzchar(Sys.getenv("SAMPLETIDY_MIG088_NO_SNAPSHOT"))) {
  stopifnot(!identical(normalizePath(db), normalizePath(st_config("live_db"))))
  env$mig088_backup <- function(db, snapshot_dir, .now = NULL) {
    with_db_write(function(con) DBI::dbExecute(con, "CHECKPOINT"), db = db)
    "(rehearsal: no snapshot)"
  }
}
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig088_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '088-backfill-ingest-file-uuid-asset') AS log_088 FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT state, count(*) AS n, count(uuid_asset) AS linked FROM ingest_file GROUP BY 1 ORDER BY 1"))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig088_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
