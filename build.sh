#!/bin/zsh
# Builds EchoType.app from src/main.swift
set -euo pipefail
cd "$(dirname "$0")"

APP="EchoType.app"
BIN="$APP/Contents/MacOS/EchoType"

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

# Bundle the whisper.cpp engine + its dylibs so the shipped app needs no
# Homebrew. Requires `brew install whisper-cpp` on THIS build machine only.
if command -v whisper-cli >/dev/null 2>&1; then
    ./vendor-whisper.sh "$APP"
elif [[ -x "$APP/Contents/Resources/whisper/bin/whisper-cli" ]]; then
    echo "Keeping already-bundled whisper.cpp engine."
else
    echo "warning: whisper-cli not found — app will fall back to a system whisper-cli at runtime." >&2
fi

# Signing:
#  - Local dev (default): use a real identity when available. Its designated
#    requirement is team + bundle ID, so TCC grants (mic/accessibility) survive
#    rebuilds. Ad-hoc signatures change every build and drop the grant.
#  - Release (RELEASE=1): force ad-hoc. An "Apple Development" cert is NOT trusted
#    by Gatekeeper on other people's Macs (spctl rejects it), so a Development-
#    signed zip is worse for distribution than an ad-hoc one. A properly notarized
#    "Developer ID" build is the real fix; ad-hoc + the installer's quarantine
#    strip is the fallback until then.
# --deep so the nested whisper binaries/dylibs are sealed with the bundle.
if [[ "${RELEASE:-0}" == "1" ]]; then
    IDENTITY=""
else
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
fi
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"

echo "Built $APP"
echo "Run:   open $APP"
