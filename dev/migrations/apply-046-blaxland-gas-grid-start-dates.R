# Apply migration 046 to the live DB: dry run, migrate, re-run (no-op), with the
# gas grid successor start dates before and after. Apply AFTER 045. Run from the
# repo root:
#   Rscript dev/migrations/apply-046-blaxland-gas-grid-start-dates.R
# Set SAMPLETIDY_MIG046_DB / SAMPLETIDY_MIG046_SNAPSHOT_DIR /
# SAMPLETIDY_MIG046_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the BACKUP CSVs to dev/migrations/.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/046-blaxland-gas-grid-start-dates.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG046_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG046_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG046_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM change_log WHERE actor = '046-blaxland-gas-grid-start-dates') AS log_046
    FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT f.site, f.date_start, f.date_end, count(*) AS n, min(f.name) AS lo, max(f.name) AS hi
    FROM feature f WHERE regexp_matches(f.name, '^B[.]G[0-9]+$') AND f.site = 'B'
      AND f.name >= 'B.G182' GROUP BY ALL ORDER BY 1, 2"))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig046_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
# Rehearsed twice on fresh copies of live at 1045 (2026-10-19), run from a git
# worktree of HEAD db6f25b: dry run clean; migrate -> 185 feature date_start
# (B.G182-B.G367, 2023-02-09 -> 2024-02-19), 0 aliases (the successors' self and
# mask_long aliases are undated), 185 change_log updates, marker 1046, nothing
# else moved; re-run already_migrated; BACKUP CSVs byte-identical. Blaxland has
# no unpadded/typo'd `old` mask (all 185 match literally too). 0 successors
# sampled before the new start (first sample 2024-02-19 Sydney, the day after
# the old grid's 044 end). Applied live 2026-10-19.
