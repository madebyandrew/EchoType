#!/bin/bash
# vendor-whisper.sh — copy the whisper.cpp CLI + server and their non-system
# dylibs into EchoType.app so the shipped app needs NO Homebrew install of
# whisper-cpp. Run by build.sh; needs `brew install whisper-cpp` on the machine
# doing the build (not on the machines running the app).
#
#   Resources/whisper/
#     bin/{whisper-cli,whisper-server}   ← rewritten to load @rpath/*
#     lib/{libwhisper,libggml,libggml-base,libomp}.dylib
#
# Every Mach-O ref to a Homebrew path is rewritten to @rpath/<name>; the
# binaries already carry an LC_RPATH of @loader_path/../lib, so the whole tree
# resolves relative to itself wherever the .app lands.
set -euo pipefail
cd "$(dirname "$0")"

APP="${1:-EchoType.app}"
IDENTITY="${2:--}"          # codesign identity, or "-" for ad-hoc
HARDENED="${3:-0}"          # 1 → sign helpers with the Hardened Runtime
DEST="$APP/Contents/Resources/whisper"

realpath_py() { /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

SRC_CLI="$(command -v whisper-cli || true)"
SRC_SRV="$(command -v whisper-server || true)"
if [[ -z "$SRC_CLI" ]]; then
    echo "vendor-whisper: whisper-cli not on PATH — run 'brew install whisper-cpp' first" >&2
    exit 1
fi
SRC_CLI="$(realpath_py "$SRC_CLI")"
CELLAR_LIB="$(cd "$(dirname "$SRC_CLI")/../lib" && pwd)"   # .../whisper-cpp/<ver>/lib

# Homebrew opt prefixes (version-independent symlinks).
GGML_LIB="$(brew --prefix ggml)/lib"
OMP_LIB="$(brew --prefix libomp)/lib"

rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/lib"

# --- binaries ---
cp "$SRC_CLI" "$DEST/bin/whisper-cli"
[[ -n "$SRC_SRV" ]] && cp "$(realpath_py "$SRC_SRV")" "$DEST/bin/whisper-server"

# --- dylibs (copy the real files, install under their canonical soname) ---
cp "$CELLAR_LIB/libwhisper.1.dylib"      "$DEST/lib/libwhisper.1.dylib"       2>/dev/null \
  || cp "$CELLAR_LIB"/libwhisper.*.dylib "$DEST/lib/libwhisper.1.dylib"
cp "$GGML_LIB/libggml.0.dylib"           "$DEST/lib/libggml.0.dylib"
cp "$GGML_LIB/libggml-base.0.dylib"      "$DEST/lib/libggml-base.0.dylib"
cp "$OMP_LIB/libomp.dylib"               "$DEST/lib/libomp.dylib"

chmod u+w "$DEST"/bin/* "$DEST"/lib/*

# --- rewrite install names to @rpath/<name> ---
install_name_tool -id @rpath/libwhisper.1.dylib   "$DEST/lib/libwhisper.1.dylib"
install_name_tool -id @rpath/libggml.0.dylib      "$DEST/lib/libggml.0.dylib"
install_name_tool -id @rpath/libggml-base.0.dylib "$DEST/lib/libggml-base.0.dylib"
install_name_tool -id @rpath/libomp.dylib         "$DEST/lib/libomp.dylib"

retarget() {  # retarget <file>  — point every Homebrew dep at @rpath/<name>
    local f="$1" dep base
    while IFS= read -r dep; do
        case "$dep" in
            /opt/homebrew/*|/usr/local/*|"$CELLAR_LIB"/*)
                base="$(basename "$dep")"
                # normalise versioned libwhisper (libwhisper.1.9.1.dylib → .1.dylib)
                [[ "$base" == libwhisper.* ]] && base="libwhisper.1.dylib"
                install_name_tool -change "$dep" "@rpath/$base" "$f" ;;
        esac
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
}

for f in "$DEST"/lib/*.dylib "$DEST"/bin/*; do retarget "$f"; done

# The binaries already have LC_RPATH @loader_path/../lib; add it only if missing.
for b in "$DEST"/bin/*; do
    otool -l "$b" | grep -q "@loader_path/../lib" || install_name_tool -add_rpath @loader_path/../lib "$b"
done

# --- re-sign (install_name_tool invalidates signatures) ---
# For a Developer ID + notarized build the helpers must be signed with the same
# identity and the Hardened Runtime, or notarization rejects them. For dev / ad-hoc
# builds a plain signature is fine (they run as a subprocess, not the app).
if [[ "$IDENTITY" != "-" && "$HARDENED" == "1" ]]; then
    SIGN=(--force --timestamp --options runtime --sign "$IDENTITY")
elif [[ "$IDENTITY" != "-" ]]; then
    SIGN=(--force --timestamp=none --sign "$IDENTITY")
else
    SIGN=(--force --timestamp=none --sign -)
fi
for f in "$DEST"/lib/*.dylib "$DEST"/bin/*; do
    codesign "${SIGN[@]}" "$f"
done

# --- sanity check: nothing may still point outside the bundle ---
leaks="$(for f in "$DEST"/bin/* "$DEST"/lib/*.dylib; do
    otool -L "$f" | tail -n +2 | awk '{print $1}' \
      | grep -E '^(/opt/homebrew|/usr/local)' | sed "s|^|  $(basename "$f"): |"
done || true)"
if [[ -n "$leaks" ]]; then
    echo "vendor-whisper: ERROR — unbundled dependencies remain:" >&2
    echo "$leaks" >&2
    echo "  (whisper-cpp's dependency layout changed — update vendor-whisper.sh)" >&2
    exit 1
fi

echo "vendor-whisper: bundled $(cd "$DEST" && ls bin | tr '\n' ' ')+ $(cd "$DEST/lib" && ls | tr '\n' ' ')"
