#!/bin/zsh
# Packages EchoType.app as EchoType.zip for a GitHub release.
#
#   ./notarize.sh   → Developer ID + Apple-notarized build (opens with a plain
#                     double-click, no Gatekeeper warning). Use this once the
#                     one-time setup in notarize.sh is done.
#   ./release.sh    → ad-hoc build (this script). Portable but un-notarized:
#                     the one-command installer opens it cleanly; a manual .zip
#                     download needs a one-time "Open Anyway" in System Settings.
set -euo pipefail
cd "$(dirname "$0")"

APP="EchoType.app"
ZIP="EchoType.zip"

if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "note: a 'Developer ID Application' cert is available — ./notarize.sh"
    echo "      produces a warning-free download. Continuing with ad-hoc…"
    echo
fi

RELEASE=1 ./build.sh

rm -f "$ZIP"
echo "Zipping $APP…"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1))"
echo
echo "Upload with:"
echo "  gh release create vX.Y.Z $ZIP --title 'EchoType vX.Y.Z' --notes '...'"
