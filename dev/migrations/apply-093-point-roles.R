# Apply migration 093 (data owner, 2026-10-29): monitoring-point roles (feature_role),
# doubted features (feature_dubious), the K.TS24 -> K.L08 rename, placeholder positions
# replaced, and the one-off mislabelling alias arms checked. Dry run, migrate, re-run
# (no-op), with table counts and db_checks(tier = "all") before and after, then the
# corpus duplicate check against the pre-093 backup (must report 0). Requires marker
# 1091 (not 1092: 093 applies whether 092 has run or not).
# Run first:  Rscript dev/migrations/093-point-roles-CHECK.R                       (must print PASS (pre))
# then:       Rscript dev/migrations/apply-093-point-roles.R
# then:       SAMPLETIDY_MIG093_CHECK=post Rscript dev/migrations/093-point-roles-CHECK.R  (PASS (post))
# Needs only the tracked INPUT CSVs. Pause the hourly auto-import first
# (touch ~/.sampletidy-autoimport-off; the script refuses on live without it) and remove
# the pause afterwards.
# Rehearsal: set SAMPLETIDY_MIG093_DB / _SNAPSHOT_DIR / _CSV_DIR / _WORK_DIR;
# SAMPLETIDY_MIG093_REQUIRES overrides the required marker on a copy older than live.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/093-point-roles.R", envir = env)
rehearsal <- nzchar(Sys.getenv("SAMPLETIDY_MIG093_DB"))
db <- Sys.getenv("SAMPLETIDY_MIG093_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG093_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG093_CSV_DIR", unset = "dev/migrations")
work_dir <- Sys.getenv("SAMPLETIDY_MIG093_WORK_DIR", unset = file.path(tempdir(), "mig093"))
input_dir <- Sys.getenv("SAMPLETIDY_MIG093_INPUT_DIR", unset = "dev/migrations")
requires <- if (rehearsal) as.integer(Sys.getenv("SAMPLETIDY_MIG093_REQUIRES", unset = env$.mig093_requires)) else
  env$.mig093_requires
if (!rehearsal && !file.exists(path.expand("~/.sampletidy-autoimport-off")))
  stop("pause the hourly auto-import first: touch ~/.sampletidy-autoimport-off")
dir.create(work_dir, recursive = TRUE, showWarnings = FALSE)
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
cat("db:", db, "\nwork_dir:", work_dir, "\n")
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(env$.mig093_counts(con))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '093-point-roles') AS log_093,
    (SELECT count(*) FROM review_queue WHERE status = 'open') AS open_review FROM schema_version"))
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
backup <- NA_character_
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig093_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir, input_dir = input_dir,
                      requires = requires)
  cat("dry_run =", dr, "->", r$status, "\n")
  if (identical(r$status, "migrated")) backup <- r$backup_path
}
report("after")
if (!is.na(backup)) {
  out <- system2("Rscript", c("dev/corpus-import/dupcheck.R", shQuote(db), shQuote(backup), shQuote(file.path(work_dir, "dupcheck"))),
                 stdout = TRUE, stderr = TRUE)
  cat(out, sep = "\n")
  if (!any(grepl("^LIKELY DUPLICATES.*: 0 analyses in 0 samples", out)))
    stop("DUPLICATE CHECK FAILED. Restore: cp ", shQuote(backup), " ", shQuote(db))
}
