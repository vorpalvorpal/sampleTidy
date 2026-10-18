# Apply migration 037 to the live DB: dry run, migrate, re-run (no-op), with
# Blaxland dust events in the 10039 EPA window before and after. Apply AFTER
# 036. Run from the repo root:
#   Rscript dev/migrations/apply-037-dust-release-mar-jul-2026.R
# Set SAMPLETIDY_MIG037_DB / SAMPLETIDY_MIG037_SNAPSHOT_DIR /
# SAMPLETIDY_MIG037_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the row-backup CSVs to dev/migrations/.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/037-dust-release-mar-jul-2026.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG037_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG037_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG037_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
LOCAL <- "(COALESCE(s.datetime, s.date) AT TIME ZONE 'UTC' AT TIME ZONE 'Australia/Sydney')::DATE"
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM analysis) AS analysis, (SELECT count(*) FROM \"sample\") AS n_sample,
    (SELECT count(*) FROM review_queue WHERE status = 'open') AS review_open,
    (SELECT count(*) FROM review_queue WHERE subkind = 'a77' AND status = 'open') AS a77_open,
    (SELECT count(*) FROM change_log WHERE actor = '037-dust-release-mar-jul-2026') AS log_037
    FROM schema_version"))
  print(DBI::dbGetQuery(con, sprintf("
    SELECT f.name AS gauge, strftime(%s, '%%Y-%%m') AS coll_month, count(DISTINCT %s) AS events,
           string_agg(DISTINCT p.name, ',') AS projects
    FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature JOIN project p ON p.uuid = s.uuid_project
    WHERE f.name IN ('B.D07', 'B.D08')
      AND s.uuid IN (SELECT a.uuid_sample FROM analysis a JOIN lab_method lm ON lm.uuid = a.uuid_lab
                       JOIN analyte an ON an.uuid = lm.uuid_analyte WHERE an.name LIKE 'dust-%%')
      AND %s BETWEEN DATE '2025-08-22' AND DATE '2026-08-21'
    GROUP BY ALL ORDER BY 1, 2", LOCAL, LOCAL, LOCAL)))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig037_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
# Rehearsed twice on fresh copies of live at 1036 (scratchpad mig037/):
# sample 19672 -> 19680, analysis 101939 -> 101971, 8 a77 items resolved
# (open review 47 -> 39), change_log +96 (88 under actor 037), marker 1037,
# B.D07/B.D08 window events 5 -> 9 each (Apr-Jul 2026 added; no Mar 2026).
# 021, 035 and 036 re-verify clean on the migrated copy.
report("after")
