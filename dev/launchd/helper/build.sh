#!/bin/bash
# Build the launcher app for the launchd auto-import job. macOS only.
#   dev/launchd/helper/build.sh <absolute-script-path> <out.app>
# The script path is compiled into the launcher (see launcher.c for why there is a launcher).
# Rebuilding changes the code signature, so macOS drops any access grant the old app had.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ID=net.robinshannon.sampletidy-autoimport
EXE=sampletidy-autoimport

[ $# -eq 2 ] || { echo "usage: build.sh <absolute-script-path> <out.app>" >&2; exit 2; }
SCRIPT="$1"; APP="${2%/}"
case "$SCRIPT" in /*) ;; *) echo "script path must be absolute: $SCRIPT" >&2; exit 2;; esac
[ -f "$SCRIPT" ] || { echo "no such script: $SCRIPT" >&2; exit 2; }
case "$SCRIPT" in *\"* | *\\*) echo "script path must not contain a double quote or backslash" >&2; exit 2;; esac

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
xcrun clang -O2 -Wall -o "$APP/Contents/MacOS/$EXE" \
  "-DSAMPLETIDY_SCRIPT=\"$SCRIPT\"" "$HERE/launcher.c"
cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>sampleTidy auto-import</string>
  <key>CFBundleDisplayName</key><string>sampleTidy auto-import</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"
codesign --force --sign - --identifier "$ID" "$APP" >&2
echo "$APP"
