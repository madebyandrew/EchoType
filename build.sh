#!/bin/zsh
# Builds EchoType.app from src/*.swift.
#
# Signing modes (in priority order):
#   SIGN_IDENTITY="Developer ID Application: …"  → sign with that identity.
#       Set HARDENED=1 to also enable the Hardened Runtime + entitlements
#       (required before notarization). notarize.sh sets both.
#   RELEASE=1                                    → ad-hoc (portable, un-notarized).
#   (default, local dev)                         → auto-pick a real cert if present
#       so TCC grants (mic / accessibility) survive rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

APP="EchoType.app"
BIN="$APP/Contents/MacOS/EchoType"
ENTITLEMENTS="src/EchoType.entitlements"

echo "Compiling…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$BIN" src/*.swift \
    -framework Cocoa -framework AVFoundation -framework SwiftUI -lsqlite3

cp src/Info.plist "$APP/Contents/Info.plist"
cp src/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Bundle the model so the app is self-contained (skipped if missing).
if [[ -f models/ggml-base.en.bin && ! -f "$APP/Contents/Resources/ggml-base.en.bin" ]]; then
    echo "Bundling Whisper model…"
    cp models/ggml-base.en.bin "$APP/Contents/Resources/"
fi

# --- resolve signing identity ---
HARDENED="${HARDENED:-0}"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$SIGN_IDENTITY"
elif [[ "${RELEASE:-0}" == "1" ]]; then
    IDENTITY="-"        # ad-hoc
    HARDENED=0
else
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')"
    IDENTITY="${IDENTITY:--}"
    HARDENED=0
fi

if [[ "$IDENTITY" == "-" ]]; then
    SIGN_ARGS=(--force --timestamp=none --sign -)          # ad-hoc
elif [[ "$HARDENED" == "1" ]]; then
    SIGN_ARGS=(--force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY")
else
    SIGN_ARGS=(--force --timestamp=none --sign "$IDENTITY") # local dev cert
fi

# Bundle the whisper.cpp engine + its dylibs so the shipped app needs no
# Homebrew. Requires `brew install whisper-cpp` on THIS build machine only.
# Pass the signing identity through so the helpers are sealed consistently.
if command -v whisper-cli >/dev/null 2>&1; then
    ./vendor-whisper.sh "$APP" "$IDENTITY" "$HARDENED"
elif [[ -x "$APP/Contents/Resources/whisper/bin/whisper-cli" ]]; then
    echo "Keeping already-bundled whisper.cpp engine (re-signing with build identity)…"
    for f in "$APP"/Contents/Resources/whisper/lib/*.dylib "$APP"/Contents/Resources/whisper/bin/*; do
        codesign "${SIGN_ARGS[@]}" "$f"
    done
else
    echo "warning: whisper-cli not found — app will fall back to a system whisper-cli at runtime." >&2
fi

# Sign the bundle last so it seals the (already-signed) nested whisper binaries.
codesign "${SIGN_ARGS[@]}" "$APP"

if [[ "$IDENTITY" == "-" ]]; then
    echo "Signed: ad-hoc"
elif [[ "$HARDENED" == "1" ]]; then
    echo "Signed: $IDENTITY (hardened runtime)"
else
    echo "Signed: $IDENTITY"
fi
codesign --verify --deep --strict "$APP" && echo "codesign --verify: OK"

echo "Built $APP"
echo "Run:   open $APP"
