#!/bin/bash
# Historical corpus import: migrations 053-055, the corpus run, checks, and a
# Sharepoint snapshot. Robin's 5-step plan (2026-10-19). Run from the repo root.
#
#   dev/corpus-import/apply-corpus-import.sh rehearsal <copy.duckdb> <work_dir>
#   dev/corpus-import/apply-corpus-import.sh live <work_dir>
#
# live: pauses the hourly auto-import (~/.sampletidy-autoimport-off) and removes the
# pause on exit; refuses if an auto-import run is in progress; takes a verified local
# backup of the live DB first (restore = cp it back); applies 053, 054, 055 (each
# takes its own verified backup and writes its BACKUP CSVs to dev/migrations/);
# ingests the local corpus copy SRC into live with archive_dir = Sharepoint
# assets/processed; runs the duplicate check and summary against the backup; then
# takes ONE Sharepoint snapshot (snapshot_db() to st_config("snapshot_dir")) and
# writes the processed/ dedupe plan (dry run only: nothing is moved).
# rehearsal: the same on a copy, everything under <work_dir>, no pause, no Sharepoint.
set -euo pipefail
MODE="${1:?mode: rehearsal|live}"
LIVE="$HOME/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb"
SRC="${SAMPLETIDY_CORPUS_SRC:-$PWD/scratchpad/2026-10-19-corpus/src}"
[ -f DESCRIPTION ] && grep -q '^Package: sampleTidy' DESCRIPTION || { echo "run from the sampleTidy repo root"; exit 1; }
[ -d "$SRC/processed" ] && [ -d "$SRC/unprocessed" ] || { echo "corpus copy not found: $SRC"; exit 1; }
if [ "$MODE" = live ]; then
  DB="$LIVE"; WORK="${2:?work_dir}"
  [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "not on main"; exit 1; }
  git diff --quiet -- R dev tests inst DESCRIPTION NAMESPACE || { echo "uncommitted code changes"; exit 1; }
elif [ "$MODE" = rehearsal ]; then
  DB="${2:?copy.duckdb}"; WORK="${3:?work_dir}"
  [ "$(cd "$(dirname "$DB")" && pwd)/$(basename "$DB")" != "$LIVE" ] || { echo "rehearsal DB is the live DB"; exit 1; }
else echo "mode must be rehearsal or live"; exit 1; fi
mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
LOG="$WORK/apply.log"; exec > >(tee -a "$LOG") 2>&1
echo "=== $(date '+%F %T') corpus import ($MODE) at $(git rev-parse --short HEAD); db=$DB"

PAUSE="$HOME/.sampletidy-autoimport-off"
if [ "$MODE" = live ]; then
  if pgrep -f "dev/auto-import.R" >/dev/null; then echo "an auto-import run is in progress; try again later"; exit 1; fi
  PAUSED_BY_US=0
  if [ ! -f "$PAUSE" ]; then touch "$PAUSE"; PAUSED_BY_US=1; fi
  trap '[ "$PAUSED_BY_US" = 1 ] && rm -f "$PAUSE" && echo "auto-import pause removed"' EXIT
  echo "auto-import paused ($PAUSE)"
  sleep 2; if pgrep -f "dev/auto-import.R" >/dev/null; then echo "an auto-import run started; aborting"; exit 1; fi
fi

# 1. verified backup (local) of the DB as it is before anything
BK_DIR="$WORK/backup"; [ "$MODE" = live ] && BK_DIR="$HOME/Library/Application Support/org.R-project.R/R/sampleTidy/migration-backups"
mkdir -p "$BK_DIR"
BEFORE="$BK_DIR/monitoring_pre-corpus-import_$(date -u +%Y%m%dT%H%M%SZ).duckdb"
Rscript -e '
a <- commandArgs(TRUE); suppressMessages(devtools::load_all(".", quiet = TRUE))
cnt <- function(con) vapply(c("sample","analysis","feature_alias","asset","ingest_file","review_queue","change_log","schema_version"),
  function(t) DBI::dbGetQuery(con, sprintf("SELECT count(*) FROM \"%s\"", t))[[1]], numeric(1))
n0 <- with_db_write(function(con) { DBI::dbExecute(con, "CHECKPOINT"); n <- cnt(con)
  stopifnot(file.copy(a[[1]], a[[2]], overwrite = FALSE)); n }, db = a[[1]])
v <- DBI::dbConnect(duckdb::duckdb(), a[[2]], read_only = TRUE); n1 <- cnt(v); DBI::dbDisconnect(v, shutdown = TRUE)
stopifnot(identical(n0, n1)); cat("backup verified:", a[[2]], "\n"); print(n0)' "$DB" "$BEFORE"
echo "restore if needed: cp '$BEFORE' '$DB'"

# 2. migrations 053-055 (each: dry run, migrate, re-run = already_migrated)
for m in 053-corpus-feature-aliases 054-hold-2400-7400-07 055-rehash-sharepoint-rewritten-assets; do
  n="${m%%-*}"
  if [ "$MODE" = live ]; then
    Rscript "dev/migrations/apply-$m.R"
  else
    mkdir -p "$WORK/mig$n/snap" "$WORK/mig$n/csv"
    env "SAMPLETIDY_MIG${n}_DB=$DB" "SAMPLETIDY_MIG${n}_SNAPSHOT_DIR=$WORK/mig$n/snap" \
        "SAMPLETIDY_MIG${n}_CSV_DIR=$WORK/mig$n/csv" Rscript "dev/migrations/apply-$m.R"
  fi
done

# 3. the corpus run
Rscript dev/corpus-import/run-corpus.R "$DB" "$WORK" "$MODE" "$SRC"

# 4. checks against the pre-import backup
Rscript dev/corpus-import/summary.R "$DB" "$BEFORE" "$WORK" > "$WORK/summary.txt" 2>&1 || true
sed -n '1,45p' "$WORK/summary.txt"
Rscript dev/corpus-import/dupcheck.R "$DB" "$BEFORE" "$WORK/dupcheck"

# 5. live only: one Sharepoint snapshot, then the processed/ dedupe plan (dry run)
if [ "$MODE" = live ]; then
  Rscript -e 'suppressMessages(devtools::load_all(".", quiet = TRUE)); p <- snapshot_db(); cat("Sharepoint snapshot:", p, "\n")'
  ASSETS="$(dirname "$(sed -n 's/^SAMPLETIDY_ARCHIVE_DIR=//p' "$HOME/.Renviron" | tail -1)")"
  Rscript dev/processed-dedupe.R --db "$DB" --root "$ASSETS" --mirror "$SRC" --plan-out "$WORK/processed-plan.csv"
  echo "processed/ dedupe plan written (NOT applied): $WORK/processed-plan.csv"
fi
echo "=== $(date '+%F %T') done"
