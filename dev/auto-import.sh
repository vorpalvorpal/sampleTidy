#!/bin/bash
# Hourly auto-import trigger (macOS). PLAN-18 sections 0, 3, 5.
# Run from Obsidian's Shell commands plugin. Does nothing unless this machine holds the
# live DB and something under input_dir (or the DB file) changed since the last good run.
# Metadata only: stat, never file contents (Files-On-Demand).
# Test overrides: SAMPLETIDY_AUTOIMPORT_{DB,INPUT,REPORT,RSCRIPT,LOG,CODE}.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"   # Obsidian's PATH lacks Rscript
HERE="$(cd "$(dirname "$0")" && pwd)"
DB="${SAMPLETIDY_AUTOIMPORT_DB:-$HOME/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb}"
[ -f "$DB" ] || exit 0                                  # not the writer machine
# Off switch: touch this file to pause auto-import; remove it to resume.
[ -f "${SAMPLETIDY_AUTOIMPORT_OFF:-$HOME/.sampletidy-autoimport-off}" ] && exit 0

if [ -n "${SAMPLETIDY_AUTOIMPORT_INPUT:-}" ]; then INPUT="$SAMPLETIDY_AUTOIMPORT_INPUT"; else
  INPUT="$(sed -n 's/^SAMPLETIDY_INPUT_DIR=//p' "$HOME/.Renviron" 2>/dev/null | tail -1)"
  [ "$(basename "$INPUT")" = input ] && INPUT="$(dirname "$INPUT")"
fi
[ -d "$INPUT" ] || exit 0
REPORT="${SAMPLETIDY_AUTOIMPORT_REPORT:-${PKM_VAULT:-$HOME/pkm}/0 Misc/00 Misc/00.09 Import triage}"
RSCRIPT="${SAMPLETIDY_AUTOIMPORT_RSCRIPT:-Rscript}"
LOG="${SAMPLETIDY_AUTOIMPORT_LOG:-$HOME/Library/Logs/sampletidy-autoimport.log}"
STATE="$REPORT/.imports.state"; GATE="$REPORT/.imports.gate"

# The Sydney date is hashed too (ruling R14): the first tick of each Sydney day
# passes the gate, so R can refresh the status note's dates.
snapshot() {
  { find "$INPUT" -mindepth 1 -maxdepth 2 ! -name .DS_Store -exec stat -f '%N|%z|%m' {} + 2>/dev/null | LC_ALL=C sort
    stat -f 'DB|%z|%m' "$DB"
    TZ=Australia/Sydney date +%F; } | shasum -a 256 | cut -d' ' -f1
}

NOW="$(snapshot)"
if [ -f "$GATE" ] && [ -f "$STATE" ] && [ "$(cat "$GATE")" = "$NOW" ] \
   && ! grep -Eq '"pending"[[:space:]]*:[[:space:]]*true' "$STATE"; then
  exit 0
fi

mkdir -p "$(dirname "$LOG")"
# Run the last commit on main, never the working tree: a development session's
# uncommitted edits must not reach the live DB. A detached worktree outside the repo
# is moved to main's commit on every run. CODE overrides it (tests).
RUN="${SAMPLETIDY_AUTOIMPORT_CODE:-}"
if [ -z "$RUN" ]; then
  REPO="$(dirname "$HERE")"; RUN="$HOME/Library/Application Support/sampleTidy-run"
  if [ -d "$RUN/.git" ] || [ -f "$RUN/.git" ]; then
    git -C "$RUN" checkout -q --detach "$(git -C "$REPO" rev-parse main)" >>"$LOG" 2>&1
  else
    git -C "$REPO" worktree prune >>"$LOG" 2>&1
    git -C "$REPO" worktree add -q --detach "$RUN" main >>"$LOG" 2>&1
  fi || { echo "=== $(date '+%Y-%m-%d %H:%M:%S') could not prepare $RUN" >>"$LOG"; exit 1; }
fi
{ echo "=== $(date '+%Y-%m-%d %H:%M:%S') auto-import start ($(git -C "$RUN" rev-parse --short HEAD 2>/dev/null || echo "$RUN"))"
  SAMPLETIDY_AUTOIMPORT_INPUT="$INPUT" SAMPLETIDY_AUTOIMPORT_DB="$DB" \
  SAMPLETIDY_AUTOIMPORT_REPORT="$REPORT" "$RSCRIPT" "$RUN/dev/auto-import.R"; } >>"$LOG" 2>&1
rc=$?
if [ $rc -eq 0 ]; then mkdir -p "$REPORT" && snapshot >"$GATE"; fi   # post-run: R's own clean-up is not a change
exit $rc
