# Apply migration 042 to the live DB: dry run, migrate, re-run (no-op), with
# Blaxland dust events in the 10039 EPA window before and after. Apply AFTER
# 041. Run from the repo root:
#   Rscript dev/migrations/apply-042-dust-release-aug-2026.R
# Set SAMPLETIDY_MIG042_DB / SAMPLETIDY_MIG042_SNAPSHOT_DIR /
# SAMPLETIDY_MIG042_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the row-backup CSVs to dev/migrations/.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/042-dust-release-aug-2026.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG042_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG042_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG042_CSV_DIR", unset = "dev/migrations")
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
    (SELECT count(*) FROM change_log WHERE actor = '042-dust-release-aug-2026') AS log_042
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
  r <- env$mig042_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
# Rehearsal results: see MIGRATIONS.md row 1042.
report("after")
