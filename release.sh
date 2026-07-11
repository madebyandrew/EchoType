#!/bin/zsh
# Builds EchoType.app and packages it as a zip for a GitHub release.
# Run ./build.sh first (or this script runs it for you).
set -euo pipefail
cd "$(dirname "$0")"

APP="EchoType.app"
ZIP="EchoType.zip"

[[ -d "$APP" ]] || ./build.sh

rm -f "$ZIP"
echo "Zipping $APP…"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1))"
echo
echo "Upload with:"
echo "  gh release create vX.Y.Z $ZIP --title vX.Y.Z --notes '...'"
