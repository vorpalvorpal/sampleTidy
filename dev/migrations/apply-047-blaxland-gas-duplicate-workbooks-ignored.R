# Apply migration 047 to the live DB: dry run, migrate, re-run (no-op), with the
# two ingest_file rows and the 2400-7286-* project dates before and after. Apply
# AFTER 046. Run from the repo root:
#   Rscript dev/migrations/apply-047-blaxland-gas-duplicate-workbooks-ignored.R
# Set SAMPLETIDY_MIG047_DB / SAMPLETIDY_MIG047_SNAPSHOT_DIR /
# SAMPLETIDY_MIG047_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the BACKUP CSVs to dev/migrations/.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/047-blaxland-gas-duplicate-workbooks-ignored.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG047_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG047_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG047_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '047-blaxland-gas-duplicate-workbooks-ignored') AS log_047
    FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT hash, filename, state, state_reason, adapter, tier FROM ingest_file
    WHERE hash IN ('5755b9b9ed6a57b6bbc0fee5d822004d', '7a4b94c9cde7fc65216c5246e7056f50')"), right = FALSE)
  print(DBI::dbGetQuery(con, "SELECT name, date_start, date_end FROM project
    WHERE name IN ('2400-7286-03-01', '2400-7286-12') ORDER BY name"))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig047_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# Rehearsed twice on fresh copies of live at 1046 (2026-10-19), run from a git
# worktree of HEAD 742b658: dry run clean; migrate -> 2 ingest_file rows
# (ignored, acirl_gas_xlsx/format), project 2400-7286-12 date_start/date_end
# 2023-12-08 -> 2023-12-18, 4 change_log rows, marker 1047, nothing else moved;
# re-run already_migrated; BACKUP CSVs byte-identical. E2E on the first copy:
# ingest_dir over both workbooks -> 2 ignored, 0 events, 0 samples, 0 review
# items; again under new names/paths with reconsider = TRUE -> the same; an
# inbox_run email folder holding both -> not ingested, folder filed, 0 rows.
# Control (pre-047 copy): the same ingest commits 386 samples, 2 review items.
# Applied live 2026-10-19.
