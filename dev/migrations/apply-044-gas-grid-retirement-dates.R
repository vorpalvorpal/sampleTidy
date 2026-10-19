# Apply migration 044 to the live DB: dry run, migrate, re-run (no-op), with the
# old gas grid retirement dates before and after. Apply AFTER 043. Run from the
# repo root:
#   Rscript dev/migrations/apply-044-gas-grid-retirement-dates.R
# Set SAMPLETIDY_MIG044_DB / SAMPLETIDY_MIG044_SNAPSHOT_DIR /
# SAMPLETIDY_MIG044_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the BACKUP CSVs to dev/migrations/.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/044-gas-grid-retirement-dates.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG044_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG044_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG044_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '044-gas-grid-retirement-dates') AS log_044
    FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT f.site, f.date_end, count(*) AS n, min(f.name) AS lo, max(f.name) AS hi
    FROM feature f WHERE regexp_matches(f.name, '^[BK][.]G[0-9]+$') AND f.site = substr(f.name, 1, 1)
      AND f.date_end IS NOT NULL GROUP BY ALL ORDER BY 1, 2"))
  print(DBI::dbGetQuery(con, "SELECT f.site, fa.date_end, count(*) AS n_041_aliases
    FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE fa.comments LIKE '041 %' GROUP BY ALL ORDER BY 1, 2"))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig044_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# Rehearsed twice on fresh copies of live at 1043 (2026-10-19, md5 92dacd50),
# run from a git worktree of HEAD 5b95448 (R/inbox.R had uncommitted edits):
# dry run clean; migrate -> 338 feature date_end (B.G001-178 2023-02-08 ->
# 2024-02-18; K.G026-185 2023-03-08 -> 2024-03-03) + 182 041 alias date_end
# (B 108, K 74) = 520 change_log updates, marker 1044, nothing else moved;
# re-run already_migrated. Both BACKUP CSVs byte-identical. K.G01-24 (2022-01-01,
# no post-end samples) and its 9 aliases untouched. Overlap and structural
# checks calibrated against injected positives (a fake auto "B.G1" -> B.G182
# alias; a successor renamed to collide on B|G1) - both caught. Re-ingesting
# the 34 corpus gas workbooks (32 names) onto a rehearsed copy: unknown_feature
# 2,943 -> 25, all `structural` template slots (B.G201 x9, K.G365 x8, K.G366 x8).
# Applied to live the same day.
