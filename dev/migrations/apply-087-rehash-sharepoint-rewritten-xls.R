# Apply migration 087 (Robin 2026-10-26): re-hash the ACIRL .xls assets SharePoint rewrote after
# archiving. Dry run, migrate, re-run (no-op), with table counts and db_checks before and after.
# Requires marker 1086. Run from the repo root:
#   Rscript dev/migrations/apply-087-rehash-sharepoint-rewritten-xls.R
# Rehearsal: set SAMPLETIDY_MIG087_DB / _SNAPSHOT_DIR / _CSV_DIR. Unset, it targets the LIVE db and
# the live archive (the stored files are only read, never written).
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/087-rehash-sharepoint-rewritten-xls.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG087_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG087_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG087_CSV_DIR", unset = "dev/migrations")
archive_dir <- st_config("archive_dir")
# Rehearsal only: skip the whole-file snapshot (checkpoint only). Never set it for live.
if (nzchar(Sys.getenv("SAMPLETIDY_MIG087_NO_SNAPSHOT"))) {
  stopifnot(!identical(normalizePath(db), normalizePath(st_config("live_db"))))
  env$mig087_backup <- function(db, snapshot_dir, .now = NULL) {
    with_db_write(function(con) DBI::dbExecute(con, "CHECKPOINT"), db = db)
    "(rehearsal: no snapshot)"
  }
}
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir), dir.exists(archive_dir))
cat("db:", db, "\n")
x <- env$.mig087_read_inputs()
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig087_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '087-rehash-sharepoint-rewritten-xls') AS log_087 FROM schema_version"))
  n <- DBI::dbGetQuery(con, sprintf("SELECT count(*) AS n_new, (SELECT count(*) FROM asset WHERE hash IN %s) AS n_old FROM asset WHERE hash IN %s",
                                    env$.mig087_inlist(x$old_hash), env$.mig087_inlist(x$new_hash)))
  print(n)
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig087_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir, archive_dir = archive_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
