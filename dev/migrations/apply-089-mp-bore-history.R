# Apply migration 089 (Robin 2026-10-28): import the Katoomba MP #1-4 bore history (Nov 2012 -
# May 2020) from ACIRL's PDF reports, and record the PDFs as already filed in TRIM. Dry run,
# migrate, re-run (no-op), with table counts and db_checks(tier = "all") before and after, then
# the corpus duplicate check against the pre-089 backup (must report 0). Requires marker 1088.
# Run 089-mp-bore-history-CHECK.R first (it must print PASS). From the repo root:
#   Rscript dev/migrations/apply-089-mp-bore-history.R
# Needs, untracked in dev/migrations/: 089-mp-bore-history-FILES/ (the PDFs) and
# 089-mp-bore-history-TRIM.csv (record numbers). Pause the hourly auto-import first
# (touch ~/.sampletidy-autoimport-off) and remove the pause afterwards.
# Rehearsal: set SAMPLETIDY_MIG089_DB / _SNAPSHOT_DIR / _CSV_DIR / _WORK_DIR and
# SAMPLETIDY_MIG089_ARCHIVE_DIR (a scratch dir outside OneDrive; archive_file() copies each PDF
# to <archive_dir>/<uuid>/); SAMPLETIDY_MIG089_REQUIRES overrides the required marker on a copy
# older than live. With _DB set, an unset or OneDrive _ARCHIVE_DIR is refused.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/089-mp-bore-history.R", envir = env)
rehearsal <- nzchar(Sys.getenv("SAMPLETIDY_MIG089_DB"))
db <- Sys.getenv("SAMPLETIDY_MIG089_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG089_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG089_CSV_DIR", unset = "dev/migrations")
work_dir <- Sys.getenv("SAMPLETIDY_MIG089_WORK_DIR", unset = file.path(tempdir(), "mig089"))
archive_dir <- Sys.getenv("SAMPLETIDY_MIG089_ARCHIVE_DIR", unset = if (rehearsal) "" else st_config("archive_dir"))
files_dir <- Sys.getenv("SAMPLETIDY_MIG089_FILES_DIR", unset = "dev/migrations/089-mp-bore-history-FILES")
trim_csv <- Sys.getenv("SAMPLETIDY_MIG089_TRIM_CSV", unset = "dev/migrations/089-mp-bore-history-TRIM.csv")
input_dir <- Sys.getenv("SAMPLETIDY_MIG089_INPUT_DIR", unset = "dev/migrations")
requires <- if (rehearsal) as.integer(Sys.getenv("SAMPLETIDY_MIG089_REQUIRES", unset = env$.mig089_requires)) else
  env$.mig089_requires
if (rehearsal && (!nzchar(archive_dir) || grepl("CloudStorage|OneDrive", archive_dir)))
  stop("rehearsal: SAMPLETIDY_MIG089_ARCHIVE_DIR must be set to a scratch dir outside OneDrive")
dir.create(work_dir, recursive = TRUE, showWarnings = FALSE)
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir), dir.exists(archive_dir), dir.exists(files_dir), file.exists(trim_csv))
cat("db:", db, "\narchive_dir:", archive_dir, "\nwork_dir:", work_dir, "\n")
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(env$.mig089_counts(con))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '089-mp-bore-history') AS log_089,
    (SELECT count(*) FROM review_queue WHERE status = 'open') AS open_review FROM schema_version"))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
backup <- NA_character_
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig089_run(db = db, snapshot_dir = backup_dir, archive_dir = archive_dir, work_dir = work_dir,
                      files_dir = files_dir, trim_csv = trim_csv, dry_run = dr, csv_dir = csv_dir,
                      input_dir = input_dir, requires = requires)
  cat("dry_run =", dr, "->", r$status, "\n")
  if (identical(r$status, "migrated")) {
    backup <- r$backup_path
    utils::write.csv(r$new_rows, file.path(work_dir, "089-new-rows.csv"), row.names = FALSE, na = "")
  }
}
report("after")
if (!is.na(backup)) {
  out <- system2("Rscript", c("dev/corpus-import/dupcheck.R", shQuote(db), shQuote(backup), shQuote(file.path(work_dir, "dupcheck"))),
                 stdout = TRUE, stderr = TRUE)
  cat(out, sep = "\n")
  if (!any(grepl("^LIKELY DUPLICATES.*: 0 analyses in 0 samples", out)))
    stop("DUPLICATE CHECK FAILED. Restore: cp ", shQuote(backup), " ", shQuote(db))
}
