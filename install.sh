#!/bin/bash
# One-command installer for EchoType.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/madebyandrew/EchoType/main/install.sh | bash
#
# The app is fully self-contained (the whisper.cpp speech engine and model are
# bundled), so this just downloads it, drops it in /Applications, clears the
# quarantine flag so macOS opens it without the "unverified developer" wall, and
# launches it. No Homebrew, no dependencies.
set -euo pipefail

REPO="madebyandrew/EchoType"
APP_NAME="EchoType.app"
ZIP_NAME="EchoType.zip"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "error: EchoType requires an Apple Silicon Mac (M1 or later)." >&2
    exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading EchoType…"
curl -fsSL "https://github.com/${REPO}/releases/latest/download/${ZIP_NAME}" -o "$TMPDIR/$ZIP_NAME"

echo "Installing to /Applications…"
ditto -x -k "$TMPDIR/$ZIP_NAME" "$TMPDIR/extracted"
rm -rf "/Applications/${APP_NAME}"
mv "$TMPDIR/extracted/${APP_NAME}" "/Applications/${APP_NAME}"

# Downloaded via curl, so there is normally no quarantine flag — but strip it
# defensively so macOS never shows the "Apple could not verify" dialog.
xattr -dr com.apple.quarantine "/Applications/${APP_NAME}" 2>/dev/null || true

echo
echo "Installed! Opening EchoType…"
open "/Applications/${APP_NAME}"

cat <<'EOF'

One-time setup — System Settings → Privacy & Security:
  1. Accessibility → turn on EchoType (needed for the push-to-talk key and typing).
  2. Allow the Microphone prompt the first time you record.

Then hold Right Option (⌥), speak, and release.
EOF
