# Apply migration 092 (Robin 2026-10-29, "Import the gas data too"): import the Katoomba WMF
# landfill-gas CH4 readings (surface grid, buildings, biofilter, gas bores; Nov 2012 - May 2020)
# from the ACIRL PDF reports 089 and 090 already hold. Dry run, migrate, re-run (no-op), with
# table counts and db_checks(tier = "all") before and after, then the corpus duplicate check
# against the pre-092 backup (must report 0). Requires marker 1090.
# Run first:  Rscript dev/migrations/092-kat-gas-CHECK.R                       (must print PASS (pre))
# then:       Rscript dev/migrations/apply-092-kat-gas.R
# then:       SAMPLETIDY_MIG092_CHECK=post Rscript dev/migrations/092-kat-gas-CHECK.R  (PASS (post))
# Needs, untracked in dev/migrations/: 089-mp-bore-history-FILES/ and 090-kat-history-FILES/ (the
# PDFs). No TRIM CSV: every PDF is already an asset filed in TRIM by 089/090. Pause the hourly
# auto-import first (touch ~/.sampletidy-autoimport-off) and remove the pause afterwards.
# Rehearsal: set SAMPLETIDY_MIG092_DB / _SNAPSHOT_DIR / _CSV_DIR / _WORK_DIR and
# SAMPLETIDY_MIG092_ARCHIVE_DIR (a scratch dir outside OneDrive); SAMPLETIDY_MIG092_REQUIRES
# overrides the required marker on a copy older than live. With _DB set, an unset or OneDrive
# _ARCHIVE_DIR is refused.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/092-kat-gas.R", envir = env)
rehearsal <- nzchar(Sys.getenv("SAMPLETIDY_MIG092_DB"))
db <- Sys.getenv("SAMPLETIDY_MIG092_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG092_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG092_CSV_DIR", unset = "dev/migrations")
work_dir <- Sys.getenv("SAMPLETIDY_MIG092_WORK_DIR", unset = file.path(tempdir(), "mig092"))
archive_dir <- Sys.getenv("SAMPLETIDY_MIG092_ARCHIVE_DIR", unset = if (rehearsal) "" else st_config("archive_dir"))
files_root <- Sys.getenv("SAMPLETIDY_MIG092_FILES_ROOT", unset = "dev/migrations")
input_dir <- Sys.getenv("SAMPLETIDY_MIG092_INPUT_DIR", unset = "dev/migrations")
requires <- if (rehearsal) as.integer(Sys.getenv("SAMPLETIDY_MIG092_REQUIRES", unset = env$.mig092_requires)) else
  env$.mig092_requires
if (rehearsal && (!nzchar(archive_dir) || grepl("CloudStorage|OneDrive", archive_dir)))
  stop("rehearsal: SAMPLETIDY_MIG092_ARCHIVE_DIR must be set to a scratch dir outside OneDrive")
if (!rehearsal && !file.exists(path.expand("~/.sampletidy-autoimport-off")))
  stop("pause the hourly auto-import first: touch ~/.sampletidy-autoimport-off")
dir.create(work_dir, recursive = TRUE, showWarnings = FALSE)
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir), dir.exists(archive_dir), dir.exists(files_root))
cat("db:", db, "\narchive_dir:", archive_dir, "\nwork_dir:", work_dir, "\n")
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(env$.mig092_counts(con))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '092-kat-gas') AS log_092,
    (SELECT count(*) FROM review_queue WHERE status = 'open') AS open_review FROM schema_version"))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
backup <- NA_character_
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig092_run(db = db, snapshot_dir = backup_dir, archive_dir = archive_dir, work_dir = work_dir,
                      files_root = files_root, dry_run = dr, csv_dir = csv_dir, input_dir = input_dir,
                      requires = requires)
  cat("dry_run =", dr, "->", r$status, "\n")
  if (identical(r$status, "migrated")) {
    backup <- r$backup_path
    utils::write.csv(r$new_rows, file.path(work_dir, "092-new-rows.csv"), row.names = FALSE, na = "")
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
