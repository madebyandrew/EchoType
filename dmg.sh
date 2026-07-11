#!/bin/zsh
# Packages EchoType.app into a drag-to-Applications DMG for sharing.
# Run ./build.sh first.
set -euo pipefail
cd "$(dirname "$0")"

APP="EchoType.app"
DMG="EchoType.dmg"
VOLNAME="EchoType"
STAGE="$(mktemp -d)"

[[ -d "$APP" ]] || { echo "error: $APP not found — run ./build.sh first" >&2; exit 1; }

echo "Staging DMG contents…"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
echo "Creating $DMG…"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

rm -rf "$STAGE"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
