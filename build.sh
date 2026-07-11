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

# Sign with a real identity when available: its designated requirement is based on
# the team + bundle ID, so TCC grants (mic/accessibility) survive rebuilds.
# Ad-hoc signatures change with every binary change, invalidating grants each build.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"

echo "Built $APP"
echo "Run:   open $APP"
