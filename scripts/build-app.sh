#!/bin/bash
# Builds build/OpenHeadPointer.app. A real .app bundle is needed so macOS attributes the
# Camera and Accessibility permissions to OpenHeadPointer instead of to your terminal.
#
#   scripts/build-app.sh            # release build
#   CONFIG=debug scripts/build-app.sh
#   SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/OpenHeadPointer.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/OpenHeadPointer"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenHeadPointer"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# A stable identity keeps the Accessibility grant across rebuilds. Ad-hoc ("-") signing
# changes the code hash each build, so macOS treats each build as a new app.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # No -v: a self-signed "OpenHeadPointer Dev" (or older "GazeControl Dev") certificate isn't "trusted", but codesign can still use it.
  IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|OpenHeadPointer Dev|GazeControl Dev/ {print $2; exit}')"
fi
codesign --force --sign "${IDENTITY:--}" "$APP"

echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"
