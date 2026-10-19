# Apply migration 043 to the live DB: dry run, migrate, re-run (no-op), with the 8
# Blaxland Sep 2025 values and review items before and after. Apply AFTER 041
# (042 is independent). Run from the repo root:
#   Rscript dev/migrations/apply-043-sep-2025-workbook-supersedes-pdf.R
# Set SAMPLETIDY_MIG043_DB / SAMPLETIDY_MIG043_SNAPSHOT_DIR to point it at a
# scratch copy (rehearsal); unset, it targets the LIVE db.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/043-sep-2025-workbook-supersedes-pdf.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG043_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG043_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
stopifnot(dir.exists(backup_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM analysis) AS analysis,
    (SELECT count(*) FROM review_queue WHERE status = 'open') AS open_review,
    (SELECT count(*) FROM change_log WHERE actor = '043-sep-2025-workbook-supersedes-pdf') AS log_043
    FROM schema_version"))
  st <- env$.mig043_state(con)
  print(st[, c("feature", "analyte", "value", "status")])
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig043_run(db = db, snapshot_dir = backup_dir, dry_run = dr)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
