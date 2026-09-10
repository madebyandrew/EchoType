#!/bin/bash
# notarize.sh — build a Developer ID–signed, Apple-notarized, stapled EchoType.zip
# for the GitHub release. After this, the download opens with a plain double-click
# on any Mac, no Gatekeeper warning.
#
# ── One-time setup ────────────────────────────────────────────────────────────
#   1. Create a "Developer ID Application" certificate (once, reusable for every
#      Mac app you ever ship):
#        Xcode → Settings → Accounts → <your Apple ID> → Manage Certificates
#              → +  → "Developer ID Application"
#      Confirm it landed:  security find-identity -v -p codesigning
#
#   2. Store notarization credentials in the keychain (once):
#        xcrun notarytool store-credentials echotype-notary \
#          --apple-id  "you@example.com" \
#          --team-id   "XXXXXXXXXX" \
#          --password  "abcd-efgh-ijkl-mnop"      # app-specific password from
#                                                 # appleid.apple.com
#
# ── Usage ────────────────────────────────────────────────────────────────────
#   ./notarize.sh                       # auto-detect the Developer ID identity
#   NOTARY_PROFILE=my-profile ./notarize.sh
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./notarize.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="EchoType.app"
ZIP="EchoType.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-echotype-notary}"

# --- find the Developer ID identity ---
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "notarize: no 'Developer ID Application' certificate found." >&2
    echo "          Create one in Xcode → Settings → Accounts → Manage Certificates," >&2
    echo "          or set SIGN_IDENTITY=… explicitly. See the header of this script." >&2
    exit 1
fi
echo "notarize: signing identity → $SIGN_IDENTITY"

# --- build, Developer ID + Hardened Runtime ---
SIGN_IDENTITY="$SIGN_IDENTITY" HARDENED=1 ./build.sh

# --- package ---
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# --- submit to Apple and wait for the verdict ---
echo "notarize: uploading to Apple (keychain profile: $NOTARY_PROFILE)…"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait; then
    echo "notarize: submission failed. Get the log with:" >&2
    echo "  xcrun notarytool history --keychain-profile $NOTARY_PROFILE" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
fi

# --- staple the ticket into the app, then re-zip the stapled copy ---
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
spctl -a -vvv -t exec "$APP" || true          # expect: "accepted / Notarized Developer ID"
echo "notarize: done → $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "Upload:  gh release create vX.Y.Z $ZIP --title 'EchoType vX.Y.Z' --notes '…'"
