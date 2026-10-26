# Apply migration 084 (Robin 2026-10-26): replace three damaged archived PDFs with their
# intact email originals and re-hash the asset rows; re-parse ES2602084's QC report. Dry run,
# migrate, re-run (no-op), with table counts and db_checks(tier = "all") before and after.
# Requires marker 1083. Run from the repo root:
#   Rscript dev/migrations/apply-084-replace-damaged-pdfs.R
# Rehearsal: set SAMPLETIDY_MIG084_DB / _SNAPSHOT_DIR / _CSV_DIR / _ARCHIVE_DIR (a scratch copy
# of the three processed/<uuid>/ folders). Unset, it targets the LIVE db and the live archive.
# The originals must be in dev/migrations/084-replace-damaged-pdfs-ORIGINALS/<uuid>/<filename>.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/084-replace-damaged-pdfs.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG084_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG084_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG084_CSV_DIR", unset = "dev/migrations")
archive_dir <- Sys.getenv("SAMPLETIDY_MIG084_ARCHIVE_DIR", unset = st_config("archive_dir"))
# Rehearsal only: SAMPLETIDY_MIG084_NO_SNAPSHOT=1 skips the whole-file snapshot (checkpoint
# only), so a rehearsal does not put a third DB copy on disk. Never set it for live.
if (nzchar(Sys.getenv("SAMPLETIDY_MIG084_NO_SNAPSHOT"))) {
  stopifnot(!identical(normalizePath(db), normalizePath(st_config("live_db"))))
  env$mig084_backup <- function(db, snapshot_dir, .now = NULL) {
    with_db_write(function(con) DBI::dbExecute(con, "CHECKPOINT"), db = db)
    "(rehearsal: no snapshot)"
  }
}
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir), dir.exists(archive_dir))
cat("db:", db, "\narchive:", archive_dir, "\n")
ids <- env$.mig084_plan_rows$id[env$.mig084_plan_rows$op == "replace_file"]
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(as.data.frame(env$.mig084_counts(con)))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '084-replace-damaged-pdfs') AS log_084 FROM schema_version"))
  a <- DBI::dbGetQuery(con, sprintf("SELECT uuid, filename, hash FROM asset WHERE uuid IN ('%s') ORDER BY uuid",
                                    paste(ids, collapse = "','")))
  a$file_hash <- vapply(file.path(archive_dir, a$uuid, a$filename), rlang::hash_file, "")
  print(a[, c("filename", "hash", "file_hash")], row.names = FALSE)
  print(DBI::dbGetQuery(con, "SELECT work_order, kind, status, message FROM lab_qc_report
    WHERE uuid_asset = 'ed2c1409-db04-4414-a348-93f5867fd1d1'"))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig084_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir, archive_dir = archive_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
