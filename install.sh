#!/bin/bash
# One-command installer for EchoType.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/madebyandrew/EchoType/main/install.sh | bash
set -euo pipefail

REPO="madebyandrew/EchoType"
APP_NAME="EchoType.app"
ZIP_NAME="EchoType.zip"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "error: EchoType requires an Apple Silicon Mac (M1 or later)." >&2
    exit 1
fi

# --- Homebrew: install if missing, or just load it into PATH if already there ---
if ! command -v brew >/dev/null 2>&1; then
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    else
        echo "Installing Homebrew…"
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        eval "$(/opt/homebrew/bin/brew shellenv)"
        # Persist for future terminal sessions.
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
    fi
fi

# --- whisper-cpp: the local speech-to-text engine EchoType shells out to ---
if ! command -v whisper-cli >/dev/null 2>&1; then
    echo "Installing whisper-cpp (speech engine)…"
    brew install whisper-cpp
fi

# --- Download and install the app ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading EchoType…"
curl -fsSL "https://github.com/${REPO}/releases/latest/download/${ZIP_NAME}" -o "$TMPDIR/$ZIP_NAME"

echo "Installing to /Applications…"
ditto -x -k "$TMPDIR/$ZIP_NAME" "$TMPDIR/extracted"
rm -rf "/Applications/${APP_NAME}"
mv "$TMPDIR/extracted/${APP_NAME}" "/Applications/${APP_NAME}"

# Downloaded via curl (not a browser), so this normally has no quarantine flag —
# but strip it defensively in case a redirect ever routes through something that adds one.
xattr -cr "/Applications/${APP_NAME}" 2>/dev/null || true

echo
echo "Installed! Opening EchoType…"
open "/Applications/${APP_NAME}"

cat <<'EOF'

Two one-time steps, both in System Settings → Privacy & Security:
  1. Accessibility → turn on EchoType (needed for the push-to-talk key and typing).
  2. Allow the Microphone prompt the first time you record.

Then hold Right Option (⌥), speak, and release.
EOF
