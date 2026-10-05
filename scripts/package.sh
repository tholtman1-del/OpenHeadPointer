#!/bin/bash
# Packages OpenHeadPointer into dist/OpenHeadPointer.dmg (drag-to-Applications installer) and
# dist/OpenHeadPointer.zip. Prototype: the app is ad-hoc signed, not notarized, so the first
# launch on another Mac needs right-click → Open (see README).
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="-" scripts/build-app.sh

rm -rf dist
mkdir -p dist/dmg
cp -R build/OpenHeadPointer.app dist/dmg/
ln -s /Applications dist/dmg/Applications

hdiutil create -quiet -volname "OpenHeadPointer" -srcfolder dist/dmg -ov -format UDZO dist/OpenHeadPointer.dmg
ditto -c -k --norsrc --noextattr --noqtn --keepParent build/OpenHeadPointer.app dist/OpenHeadPointer.zip
rm -rf dist/dmg

echo "Created dist/OpenHeadPointer.dmg and dist/OpenHeadPointer.zip"
