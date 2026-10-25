#!/bin/bash
# Hourly auto-import trigger (macOS). PLAN-18 sections 0, 3, 5.
# Run by launchd on the Mac (dev/launchd/); Obsidian's Shell commands trigger was retired 2026-10-25. Does nothing unless this machine holds the
# live DB and something under input_dir (or the DB file) changed since the last good run.
# Metadata only: stat, never file contents (Files-On-Demand).
# Test overrides: SAMPLETIDY_AUTOIMPORT_{DB,INPUT,REPORT,RSCRIPT,LOG,CODE,OFF,NOTIFY,STALE_HOURS}.
# R-22.H (Robin 2026-10-25): an atomic mkdir lock, and a run-health record
# ($REPORT/.imports.health) that drives retry-after-failure, one notification per
# failed run, a once-per-Sydney-day "no success for N hours" notification, and the
# SAMPLETIDY_AUTOIMPORT_PREV_FAILURE text that import_status() shows under Problems.
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
LOCK="$REPORT/.imports.lock"; HEALTH="$REPORT/.imports.health"; NOTIFIED="$REPORT/.imports.notified"
NOTIFY="${SAMPLETIDY_AUTOIMPORT_NOTIFY:-}"
STALE_HOURS="${SAMPLETIDY_AUTOIMPORT_STALE_HOURS:-24}"
mkdir -p "$(dirname "$LOG")" "$REPORT"
logline() { echo "=== $(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

notify() {   # notify <title> <message>
  if [ -n "$NOTIFY" ]; then "$NOTIFY" "$1" "$2"
  else osascript -e "display notification \"${2//\"/\\\"}\" with title \"${1//\"/\\\"}\"" >/dev/null 2>&1; fi
}
# Notify once per key (kept in $NOTIFIED).
notify_once() {   # notify_once <key> <title> <message>
  grep -qxF -- "$1" "$NOTIFIED" 2>/dev/null && return 0
  echo "$1" >>"$NOTIFIED"; notify "$2" "$3" || true
}
jget() { sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"?([^",}]*)"?.*/\1/p' "$HEALTH" 2>/dev/null | head -1; }
utc_epoch() { date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null; }
write_health() {   # write_health <state> <pid> <started> <ended|""> <rc|""> <last_success|"">
  local q; q() { if [ -n "$1" ] && [ "$1" != null ]; then printf '"%s"' "$1"; else printf null; fi; }
  printf '{"state":"%s","pid":%s,"started_at":%s,"ended_at":%s,"rc":%s,"last_success_at":%s}\n' \
    "$1" "${2:-null}" "$(q "$3")" "$(q "$4")" "${5:-null}" "$(q "$6")" >"$HEALTH.tmp.$$" && mv "$HEALTH.tmp.$$" "$HEALTH"
}

# Atomic lock (R-22.H): mkdir is the test-and-set. A lock whose PID is dead, or
# whose directory is older than 2 h, is taken over; a fresh live one means a run
# is in progress. Released on every exit path.
HAVE_LOCK=
trap '[ -n "$HAVE_LOCK" ] && rm -rf "$LOCK"' EXIT
if ! mkdir "$LOCK" 2>/dev/null; then
  lpid="$(head -1 "$LOCK/pid" 2>/dev/null)"
  if { [ -n "$lpid" ] && ! kill -0 "$lpid" 2>/dev/null; } || [ -n "$(find "$LOCK" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then
    mv "$LOCK" "$LOCK.dead.$$" 2>/dev/null && rm -rf "$LOCK.dead.$$"
    logline "took over a stale lock (pid ${lpid:-none})"
  fi
  mkdir "$LOCK" 2>/dev/null || { logline "auto-import already in progress (lock held by pid ${lpid:-?}); skipping"; exit 0; }
fi
HAVE_LOCK=1; echo $$ >"$LOCK/pid"

# Previous run (R-22.H): a record still "running" while we hold the lock is a
# crash; a non-zero rc is a failure. Either retries past the gate and is notified
# once per failed started_at; the text goes to R for the status note.
export SAMPLETIDY_AUTOIMPORT_PREV_FAILURE=""
p_state="$(jget state)"; p_rc="$(jget rc)"; p_start="$(jget started_at)"; p_succ="$(jget last_success_at)"
[ "$p_succ" = null ] && p_succ=""
RETRY=
if [ "$p_state" = running ]; then
  SAMPLETIDY_AUTOIMPORT_PREV_FAILURE="The import started $p_start did not finish"; RETRY=1
elif [ "$p_state" = done ] && [ -n "$p_rc" ] && [ "$p_rc" != null ] && [ "$p_rc" != 0 ]; then
  SAMPLETIDY_AUTOIMPORT_PREV_FAILURE="The import started $p_start failed (rc $p_rc)"; RETRY=1
fi
[ -n "$RETRY" ] && notify_once "fail:$p_start" "sampleTidy import failed" "$SAMPLETIDY_AUTOIMPORT_PREV_FAILURE; retrying"
# Staleness: no success for STALE_HOURS, once per Sydney day, even if the gate skips.
if [ -n "$p_succ" ] && ep="$(utc_epoch "$p_succ")" && [ $(( $(date +%s) - ep )) -gt $(( STALE_HOURS * 3600 )) ]; then
  notify_once "stale:$(TZ=Australia/Sydney date +%F)" "sampleTidy import stale" "No successful import since $p_succ (over $STALE_HOURS hours)"
fi

# The Sydney date is hashed too (ruling R14): the first tick of each Sydney day
# passes the gate, so R can refresh the status note's dates.
snapshot() {
  { find "$INPUT" -mindepth 1 -maxdepth 2 ! -name .DS_Store -exec stat -f '%N|%z|%m' {} + 2>/dev/null | LC_ALL=C sort
    stat -f 'DB|%z|%m' "$DB"
    TZ=Australia/Sydney date +%F; } | shasum -a 256 | cut -d' ' -f1
}

NOW="$(snapshot)"
if [ -z "$RETRY" ] && [ -f "$GATE" ] && [ -f "$STATE" ] && [ "$(cat "$GATE")" = "$NOW" ] \
   && ! grep -Eq '"pending"[[:space:]]*:[[:space:]]*true' "$STATE"; then
  exit 0
fi

# Run the last commit on main, never the working tree: a development session's
# uncommitted edits must not reach the live DB. A detached worktree outside the repo
# is moved to main's commit on every run. CODE overrides it (tests).
RUN="${SAMPLETIDY_AUTOIMPORT_CODE:-}"
if [ -z "$RUN" ]; then
  REPO="$(dirname "$HERE")"; RUN="$HOME/.local/share/sampleTidy-run"   # no spaces: Rscript mangles them in --file
  if [ -d "$RUN/.git" ] || [ -f "$RUN/.git" ]; then
    git -C "$RUN" checkout -q --detach "$(git -C "$REPO" rev-parse main)" >>"$LOG" 2>&1
  else
    git -C "$REPO" worktree prune >>"$LOG" 2>&1
    git -C "$REPO" worktree add -q --detach "$RUN" main >>"$LOG" 2>&1
  fi || { echo "=== $(date '+%Y-%m-%d %H:%M:%S') could not prepare $RUN" >>"$LOG"; exit 1; }
fi
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_health running $$ "$STARTED" "" "" "$p_succ"
{ echo "=== $(date '+%Y-%m-%d %H:%M:%S') auto-import start ($(git -C "$RUN" rev-parse --short HEAD 2>/dev/null || echo "$RUN"))"
  SAMPLETIDY_AUTOIMPORT_INPUT="$INPUT" SAMPLETIDY_AUTOIMPORT_DB="$DB" \
  SAMPLETIDY_AUTOIMPORT_REPORT="$REPORT" "$RSCRIPT" "$RUN/dev/auto-import.R"; } >>"$LOG" 2>&1
rc=$?
ENDED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; SUCC="$p_succ"; [ $rc -eq 0 ] && SUCC="$ENDED"
write_health done $$ "$STARTED" "$ENDED" "$rc" "$SUCC"
if [ $rc -eq 0 ]; then mkdir -p "$REPORT" && snapshot >"$GATE"; fi   # post-run: R's own clean-up is not a change
exit $rc
