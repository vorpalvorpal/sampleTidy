# Apply migration 039 to the live DB: dry run, migrate, re-run (no-op), with
# Blaxland standing-water-level events in the 13089 EPA window before and
# after. Apply AFTER 038. Run from the repo root:
#   Rscript dev/migrations/apply-039-swl-sep-2025-from-pdf.R
# Set SAMPLETIDY_MIG039_DB / SAMPLETIDY_MIG039_SNAPSHOT_DIR /
# SAMPLETIDY_MIG039_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the INSERTED CSV to dev/migrations/.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/039-swl-sep-2025-from-pdf.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG039_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG039_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG039_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
LOCAL <- "(COALESCE(s.datetime, s.date) AT TIME ZONE 'UTC' AT TIME ZONE 'Australia/Sydney')::DATE"
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM analysis) AS analysis, (SELECT count(*) FROM \"sample\") AS n_sample,
    (SELECT count(*) FROM review_queue WHERE status = 'open') AS review_open,
    (SELECT count(*) FROM change_log WHERE actor = '039-swl-sep-2025-from-pdf') AS log_039
    FROM schema_version"))
  print(DBI::dbGetQuery(con, sprintf("
    SELECT f.name AS bore, count(DISTINCT %s) AS swl_events,
           string_agg(DISTINCT strftime(%s, '%%Y-%%m'), ',' ORDER BY strftime(%s, '%%Y-%%m')) AS months
    FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature
    JOIN analysis a ON a.uuid_sample = s.uuid JOIN lab_method lm ON lm.uuid = a.uuid_lab
    WHERE f.name LIKE 'B.MW%%' AND lm.uuid_analyte = 'e4a4002c-ea26-4517-aca6-2706f609343d'
      AND %s BETWEEN DATE '2025-08-22' AND DATE '2026-08-21'
    GROUP BY ALL ORDER BY 1", LOCAL, LOCAL, LOCAL, LOCAL)))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig039_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
# Rehearsed twice on fresh copies of live at 1038 (scratchpad mig039/):
# analysis 101979 -> 101985, sample unchanged 19682, change_log +6 (all under
# actor 039, source_hash = the PDF's), marker 1039; window SWL events B.MW04 /
# B.MW07 / B.MW11 3 -> 4, B.MW02 / B.MW08 / B.MW09 10 -> 11 (Sep 2025 added).
# 035-038 re-verify clean on the migrated copy; both runs' INSERTED CSVs
# identical.
report("after")
