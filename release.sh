#!/bin/zsh
# Builds EchoType.app and packages it as a zip for a GitHub release.
# Run ./build.sh first (or this script runs it for you).
set -euo pipefail
cd "$(dirname "$0")"

APP="EchoType.app"
ZIP="EchoType.zip"

# Always rebuild for a release so the app is ad-hoc signed (portable across Macs)
# rather than signed with a local "Apple Development" cert that Gatekeeper rejects.
RELEASE=1 ./build.sh

rm -f "$ZIP"
echo "Zipping $APP…"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1))"
echo
echo "Upload with:"
echo "  gh release create vX.Y.Z $ZIP --title vX.Y.Z --notes '...'"
