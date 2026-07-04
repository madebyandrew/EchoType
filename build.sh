#!/bin/zsh
# Builds FlowLocal.app from src/main.swift
set -euo pipefail
cd "$(dirname "$0")"

APP="FlowLocal.app"
BIN="$APP/Contents/MacOS/FlowLocal"

echo "Compiling…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$BIN" src/*.swift \
    -framework Cocoa -framework AVFoundation -framework SwiftUI -lsqlite3

cp src/Info.plist "$APP/Contents/Info.plist"

# Bundle the model so the app is self-contained (skipped if missing).
if [[ -f models/ggml-base.en.bin && ! -f "$APP/Contents/Resources/ggml-base.en.bin" ]]; then
    echo "Bundling Whisper model…"
    cp models/ggml-base.en.bin "$APP/Contents/Resources/"
fi

# Ad-hoc signature keeps TCC permissions (mic/accessibility) stable across rebuilds.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run:   open $APP"
