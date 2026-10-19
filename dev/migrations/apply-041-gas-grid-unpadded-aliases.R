# Apply migration 041 to the live DB: dry run, migrate, re-run (no-op), with
# the gas-grid alias counts before and after. Apply AFTER 040. Run from the
# repo root:
#   Rscript dev/migrations/apply-041-gas-grid-unpadded-aliases.R
# Set SAMPLETIDY_MIG041_DB / SAMPLETIDY_MIG041_SNAPSHOT_DIR /
# SAMPLETIDY_MIG041_CSV_DIR to point it at a scratch copy (rehearsal); unset,
# it targets the LIVE db and writes the INSERTED CSV to dev/migrations/.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/041-gas-grid-unpadded-aliases.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG041_DB", unset = st_config("live_db"))
# Local backup (the OneDrive snapshot_dir is slow/unreliable over this link).
backup_dir <- Sys.getenv("SAMPLETIDY_MIG041_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG041_CSV_DIR", unset = "dev/migrations")
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker,
    (SELECT count(*) FROM feature_alias) AS feature_alias,
    (SELECT count(*) FROM change_log WHERE actor = '041-gas-grid-unpadded-aliases') AS log_041
    FROM schema_version"))
  print(DBI::dbGetQuery(con, "SELECT f.site, count(*) AS n_041_aliases, min(fa.name) AS first, max(fa.name) AS last
    FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE fa.comments LIKE '041 %' GROUP BY 1 ORDER BY 1"))
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig041_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
# Rehearsed twice on fresh copies of live at 1040 (2026-10-19, md5 c3caf489),
# run from a git worktree of HEAD 7dee2a5 (R/ had others' uncommitted edits):
# dry run clean; migrate -> feature_alias 2285 -> 2476 (+191: B 108, K 83),
# change_log +191 inserts, marker 1041, nothing else moved; re-run
# already_migrated. Both INSERTED CSVs identical bar uuid/timestamps. Bounds as
# planned: 108 B rows end 2023-02-08; 9 K.G1-9 end 2022-01-01; 74 K.G26-99
# 2022-01-02..2023-03-08. Re-ingesting the 32 corpus gas workbooks (2023-04 ..
# 2025-09) onto a rehearsed copy: still 2,943 unknown_feature items, as
# designed - B.G1-99 x11 workbooks now `expired_alias` (1,089), B.G100-178
# (869) and K.G026-185 (960) `suggestion` (feature expired), 25 `structural`
# template slots (B.G201, K.G365, K.G366).
report("after")
