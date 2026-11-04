#!/bin/bash
# Install (or reinstall) the launchd auto-import trigger. macOS only.
#   dev/launchd/install.sh                    install and load
#   dev/launchd/install.sh --rebuild-helper   same, and rebuild the launcher app
#   dev/launchd/install.sh --print            write the rendered plist to stdout; change nothing
#   dev/launchd/install.sh uninstall          unload and remove (the app stays)
# launchd runs a launcher app, not /bin/bash (see helper/launcher.c). The app is built only when
# missing: rebuilding changes its code signature and macOS drops its Full Disk Access grant.
# The input directory is read the same way dev/auto-import.sh reads it (the process environment,
# then R's user environ file), so no deployment path is committed here.
set -euo pipefail
LABEL=net.robinshannon.sampletidy-autoimport
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$(dirname "$HERE")")"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="${SAMPLETIDY_HELPER_APP:-$HOME/Applications/sampleTidy auto-import.app}"
HELPER="$APP/Contents/MacOS/sampletidy-autoimport"

MODE=install REBUILD=0
case "$#:${1:-}" in
  0:) ;;
  1:uninstall) MODE=uninstall;;
  1:--rebuild-helper) REBUILD=1;;
  1:--print) MODE=print;;
  *) echo "usage: install.sh [--rebuild-helper | --print | uninstall]" >&2; exit 2;;
esac

if [ "$MODE" != print ]; then launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true; fi
if [ "$MODE" = uninstall ]; then
  rm -f "$DEST"
  echo "removed $LABEL; left $APP in place (removing it would drop its access grant)"
  exit 0
fi

# renviron_get KEY: the last `KEY=value` line of R's user environ file
# ($R_ENVIRON_USER, else ~/.Renviron), with one pair of surrounding ' or " removed.
# No ${VAR} or ~ expansion (the deployment writes absolute paths).
renviron_get() {
  local v
  v="$(sed -n "s/^$1=//p" "${R_ENVIRON_USER:-$HOME/.Renviron}" 2>/dev/null | tail -1)"
  case "$v" in \'*\') v="${v#\'}"; v="${v%\'}";; \"*\") v="${v#\"}"; v="${v%\"}";; esac
  printf '%s' "$v"
}

INPUT="${SAMPLETIDY_INPUT_DIR:-}"
[ -n "$INPUT" ] || INPUT="$(renviron_get SAMPLETIDY_INPUT_DIR)"
[ "$(basename "$INPUT")" = input ] && INPUT="$(dirname "$INPUT")"
[ -d "$INPUT" ] || { echo "no input directory (SAMPLETIDY_INPUT_DIR in the environment or ~/.Renviron)" >&2; exit 1; }

case "$REPO$INPUT$HOME$HELPER" in *[\&\<\>]*) echo "a path contains & < or >; edit the plist by hand" >&2; exit 1;; esac

# The locale launchd gives R: a UTF-8 one is needed; keep the installing shell's if it is.
LOCALE="${SAMPLETIDY_LAUNCHD_LOCALE:-${LANG:-}}"
case "$LOCALE" in *.UTF-8|*.utf8|*.UTF8|*.utf-8) ;; *) LOCALE=en_US.UTF-8;; esac
esc() { printf '%s' "$1" | sed -e 's/[|\\]/\\&/g'; }
render() {
  sed -e "s|@HELPER@|$(esc "$HELPER")|g" -e "s|@REPO@|$(esc "$REPO")|g" -e "s|@INPUT@|$(esc "$INPUT")|g" -e "s|@HOME@|$(esc "$HOME")|g" \
    -e "s|@LOCALE@|$(esc "$LOCALE")|g" "$HERE/$LABEL.plist"
}
if [ "$MODE" = print ]; then render; exit 0; fi

if [ ! -d "$APP" ] || [ "$REBUILD" = 1 ]; then
  mkdir -p "$(dirname "$APP")"
  "$HERE/helper/build.sh" "$REPO/dev/auto-import.sh" "$APP" >/dev/null
  cat <<MSG
built $APP. One-time step, because macOS asks for no grant by itself:
  System Settings > Privacy & Security > Full Disk Access > + > choose the app > switch it on.
  (If macOS instead prompts to let "sampleTidy auto-import" access files in a cloud-synced folder, Allow is enough.)
  A rebuild drops the grant, so run with --rebuild-helper only when the launcher changes.
MSG
else
  echo "kept existing $APP (use --rebuild-helper to rebuild; that drops its access grant)"
fi

render >"$DEST"
plutil -lint -s "$DEST"
launchctl bootstrap "gui/$(id -u)" "$DEST"
echo "installed $LABEL, watching $INPUT"
