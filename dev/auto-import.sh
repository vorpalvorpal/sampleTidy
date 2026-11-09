#!/bin/bash
# Hourly auto-import trigger (macOS). PLAN-18 sections 0, 3, 5.
# Run by launchd on the Mac (dev/launchd/). Does nothing unless this machine holds the
# live DB and something under input_dir (or the DB file) changed since the last good run.
# Metadata only: stat, never file contents (Files-On-Demand).
# Gate rules: never skip silently except on an unchanged gate. A listing failure
# (find error) logs, notifies once a day and exits 3 before the gate is compared; an
# empty listing never skips; the gate is written after a good run only if the listing
# works and nothing in the input changed (ctime) since the run began.
# Test overrides: SAMPLETIDY_AUTOIMPORT_{DB,INPUT,REPORT,RSCRIPT,LOG,CODE,OFF,NOTIFY,STALE_HOURS},
# SAMPLETIDY_{INPUT_DIR,REPORT_DIR,TIMEZONE} and R_ENVIRON_USER (the environ file read).
# Deployment config (process env, then R's environ file): SAMPLETIDY_NOTIFY_COMMAND is a
# single executable path, run as `<cmd> <title> <message>` for each notification (when unset,
# or not executable, the desktop notification is shown; a non-zero exit is logged only).
# SAMPLETIDY_NOTIFY_FLUSH is run with no arguments once per run, right after the lock is
# taken (e.g. to resend notifications queued while offline); its output goes to the log
# and its exit status is ignored.
# SAMPLETIDY_GATE_WATCH is a folder whose metadata listing (depth 2) joins the change hash, so a
# change there alone starts R (whose writer check then decides); unset, the hash is unchanged. A
# listing failure there hashes a fixed line instead: it never exits 3 or notifies.
# R-22.H (2026-10-25): an atomic mkdir lock, and a run-health record
# ($REPORT/.imports.health) that drives retry-after-failure, one notification per
# failed run, a once-per-local-day (SAMPLETIDY_TIMEZONE) "no success for N hours" notification, and the
# SAMPLETIDY_AUTOIMPORT_PREV_FAILURE text that appears in status.json problems.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"   # a GUI or launchd PATH may lack Rscript
HERE="$(cd "$(dirname "$0")" && pwd)"
# renviron_get KEY: the last `KEY=value` line of R's user environ file
# ($R_ENVIRON_USER, else ~/.Renviron), with one pair of surrounding ' or " removed.
# No ${VAR} or ~ expansion (the deployment writes absolute paths).
renviron_get() {
  local v
  v="$(sed -n "s/^$1=//p" "${R_ENVIRON_USER:-$HOME/.Renviron}" 2>/dev/null | tail -1)"
  case "$v" in \'*\') v="${v#\'}"; v="${v%\'}";; \"*\") v="${v#\"}"; v="${v%\"}";; esac
  printf '%s' "$v"
}

# Deployment values, resolved with no side effects: the SAMPLETIDY_AUTOIMPORT_* test
# override, then the process environment, then R's user environ file, then a default.
DB="${SAMPLETIDY_AUTOIMPORT_DB:-$HOME/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb}"
if [ -n "${SAMPLETIDY_AUTOIMPORT_INPUT:-}" ]; then INPUT="$SAMPLETIDY_AUTOIMPORT_INPUT"; else
  INPUT="${SAMPLETIDY_INPUT_DIR:-}"
  [ -n "$INPUT" ] || INPUT="$(renviron_get SAMPLETIDY_INPUT_DIR)"
  # batches arrive beside a folder named input, so watch its parent
  [ "$(basename "$INPUT")" = input ] && INPUT="$(dirname "$INPUT")"
fi
REPORT="${SAMPLETIDY_AUTOIMPORT_REPORT:-${SAMPLETIDY_REPORT_DIR:-}}"
[ -n "$REPORT" ] || REPORT="$(renviron_get SAMPLETIDY_REPORT_DIR)"
[ -n "$REPORT" ] || REPORT="$HOME/Library/Application Support/org.R-project.R/R/sampleTidy/reports"
ZONE="${SAMPLETIDY_TIMEZONE:-}"
[ -n "$ZONE" ] || ZONE="$(renviron_get SAMPLETIDY_TIMEZONE)"
[ -n "$ZONE" ] || ZONE=UTC
NOTIFY="${SAMPLETIDY_AUTOIMPORT_NOTIFY:-}"   # test override, then deployment config
[ -n "$NOTIFY" ] || NOTIFY="${SAMPLETIDY_NOTIFY_COMMAND:-}"
[ -n "$NOTIFY" ] || NOTIFY="$(renviron_get SAMPLETIDY_NOTIFY_COMMAND)"
FLUSH="${SAMPLETIDY_NOTIFY_FLUSH:-}"
[ -n "$FLUSH" ] || FLUSH="$(renviron_get SAMPLETIDY_NOTIFY_FLUSH)"
GWATCH="${SAMPLETIDY_GATE_WATCH:-}"
[ -n "$GWATCH" ] || GWATCH="$(renviron_get SAMPLETIDY_GATE_WATCH)"
LOG="${SAMPLETIDY_AUTOIMPORT_LOG:-$HOME/Library/Logs/sampletidy-autoimport.log}"
local_day() { TZ="$ZONE" date +%F; }
if [ "${1:-}" = --print-config ]; then
  printf 'DB=%s\nINPUT=%s\nREPORT=%s\nTIMEZONE=%s\nLOG=%s\nNOTIFY=%s\nNOTIFY_FLUSH=%s\nWATCH=%s\n' "$DB" "$INPUT" "$REPORT" "$ZONE" "$LOG" "$NOTIFY" "$FLUSH" "$GWATCH"
  exit 0
fi

[ -f "$DB" ] || exit 0                                  # not the writer machine
# Off switch: touch this file to pause auto-import; remove it to resume.
[ -f "${SAMPLETIDY_AUTOIMPORT_OFF:-$HOME/.sampletidy-autoimport-off}" ] && exit 0

mkdir -p "$(dirname "$LOG")"
logline() { echo "=== $(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }
if [ ! -d "$INPUT" ]; then logline "input folder not found: $INPUT"; exit 0; fi
RSCRIPT="${SAMPLETIDY_AUTOIMPORT_RSCRIPT:-Rscript}"
STATE="$REPORT/.imports.state"; GATE="$REPORT/.imports.gate"
LOCK="$REPORT/.imports.lock"; HEALTH="$REPORT/.imports.health"; NOTIFIED="$REPORT/.imports.notified"
STALE_HOURS="${SAMPLETIDY_AUTOIMPORT_STALE_HOURS:-24}"
mkdir -p "$REPORT"

notify() {   # notify <title> <message>
  if [ -n "$NOTIFY" ] && [ -x "$NOTIFY" ] && [ ! -d "$NOTIFY" ]; then
    "$NOTIFY" "$1" "$2"; local rc=$?
    [ $rc -eq 0 ] || logline "notify command exited $rc"
    return 0
  fi
  [ -z "$NOTIFY" ] || logline "notify command not executable: $NOTIFY"
  osascript -e "display notification \"${2//\"/\\\"}\" with title \"${1//\"/\\\"}\"" >/dev/null 2>&1
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
# Flush command (deployment config): once per run, before the health record is read.
if [ -n "$FLUSH" ]; then
  if [ -x "$FLUSH" ] && [ ! -d "$FLUSH" ]; then "$FLUSH" >>"$LOG" 2>&1 || true
  else logline "flush command not executable: $FLUSH"; fi
fi

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
# Staleness: no success for STALE_HOURS, once per local day (SAMPLETIDY_TIMEZONE), even if the gate skips.
if [ -n "$p_succ" ] && ep="$(utc_epoch "$p_succ")" && [ $(( $(date +%s) - ep )) -gt $(( STALE_HOURS * 3600 )) ]; then
  notify_once "stale:$(local_day)" "sampleTidy import stale" "No successful import since $p_succ (over $STALE_HOURS hours)"
fi

# The local date (SAMPLETIDY_TIMEZONE) is hashed too (ruling R14): the first tick of each local day
# passes the gate, so R can refresh the status note's dates.
# snapshot prints the hash; it returns 1 if the input cannot be listed (find's
# exit status or any stderr), leaving the listing and error in $LOCK/{list,err}.
# With a watch folder set, its sorted listing (name, ctime, mtime) is hashed last, or
# `WATCH|unlistable` when it cannot be listed; unset, nothing is added.
watch_listing() {
  local out
  if out="$(find "$GWATCH" -mindepth 1 -maxdepth 2 ! -name .DS_Store -exec stat -f '%N|%c|%m' {} + 2>"$LOCK/werr")" \
     && [ ! -s "$LOCK/werr" ]; then
    printf '%s\n' "$out" | LC_ALL=C sort
  else
    echo 'WATCH|unlistable'
  fi
}
snapshot() {
  find "$INPUT" -mindepth 1 -maxdepth 2 ! -name .DS_Store -exec stat -f '%N|%z|%m' {} + >"$LOCK/list" 2>"$LOCK/err"
  local frc=$?
  if [ $frc -ne 0 ] || [ -s "$LOCK/err" ]; then return 1; fi
  { LC_ALL=C sort "$LOCK/list"
    stat -f 'DB|%z|%m' "$DB"
    local_day
    [ -z "$GWATCH" ] || watch_listing; } | shasum -a 256 | cut -d' ' -f1
}

: >"$LOCK/started"   # ctime marker: anything newer arrived (or changed) during the run
if ! NOW="$(snapshot)"; then
  logline "cannot list $INPUT: $(head -1 "$LOCK/err")"
  notify_once "listfail:$(local_day)" "sampleTidy import cannot read its input" \
    "The input folder cannot be listed ($INPUT). launchd's bash may need Full Disk Access."
  exit 3
fi
EMPTY=
if [ ! -s "$LOCK/list" ]; then EMPTY=1; logline "input listing is empty ($INPUT); running anyway"; fi
if [ -z "$RETRY" ] && [ -z "$EMPTY" ] && [ -f "$GATE" ] && [ -f "$STATE" ] && [ "$(cat "$GATE")" = "$NOW" ] \
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
if [ $rc -eq 0 ]; then
  # Post-run gate: only if the listing works and nothing changed (by ctime; a cloud-synced
  # folder may keep server mtimes) in the input, or the watch folder when set, since the
  # marker. Otherwise leave it stale so the next tick runs.
  if POST="$(snapshot)" && [ -z "$(find "$INPUT" -mindepth 1 -maxdepth 2 ! -name .DS_Store -cnewer "$LOCK/started" 2>/dev/null)" ] \
     && { [ -z "$GWATCH" ] || [ -z "$(find "$GWATCH" -mindepth 1 -maxdepth 2 ! -name .DS_Store -cnewer "$LOCK/started" 2>/dev/null)" ]; }; then
    mkdir -p "$REPORT" && echo "$POST" >"$GATE.tmp.$$" && mv "$GATE.tmp.$$" "$GATE"
  else
    logline "input changed during the run; next tick will re-check"
  fi
fi
exit $rc
