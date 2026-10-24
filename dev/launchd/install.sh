#!/bin/bash
# Install (or reinstall) the launchd auto-import trigger. macOS only.
#   dev/launchd/install.sh            install and load
#   dev/launchd/install.sh uninstall  unload and remove
# The input directory is read from ~/.Renviron the same way dev/auto-import.sh reads it, so no
# deployment path is committed here.
set -euo pipefail
LABEL=net.robinshannon.sampletidy-autoimport
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$(dirname "$HERE")")"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = uninstall ]; then rm -f "$DEST"; echo "removed $LABEL"; exit 0; fi

INPUT="$(sed -n 's/^SAMPLETIDY_INPUT_DIR=//p' "$HOME/.Renviron" 2>/dev/null | tail -1)"
[ "$(basename "$INPUT")" = input ] && INPUT="$(dirname "$INPUT")"
[ -d "$INPUT" ] || { echo "no input directory (SAMPLETIDY_INPUT_DIR in ~/.Renviron)" >&2; exit 1; }

case "$REPO$INPUT$HOME" in *[\&\<\>]*) echo "a path contains & < or >; edit the plist by hand" >&2; exit 1;; esac
esc() { printf '%s' "$1" | sed -e 's/[|\\]/\\&/g'; }
sed -e "s|@REPO@|$(esc "$REPO")|g" -e "s|@INPUT@|$(esc "$INPUT")|g" -e "s|@HOME@|$(esc "$HOME")|g" \
  "$HERE/$LABEL.plist" >"$DEST"
plutil -lint -s "$DEST"
launchctl bootstrap "gui/$(id -u)" "$DEST"
echo "installed $LABEL, watching $INPUT"
