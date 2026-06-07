#!/bin/zsh
# === Build atm-watcher (Swift FSEvents helper) ===
# Universal binary for arm64 + x86_64 (macOS 11+).
# If xcode-select tools are missing → exit 1.
set -u
emulate -L zsh
setopt NO_UNSET PIPE_FAIL

cd "${0:A:h}" || exit 1

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
    print -u2 -- "build.sh: xcode-tools not found. Install with: xcode-select --install"
    exit 1
fi

local SRC="atm-watcher.swift"
local OUT="atm-watcher"
local TMP_ARM="${OUT}-arm64"
local TMP_X86="${OUT}-x86_64"

# Build per-arch
/usr/bin/xcrun swiftc -O -target arm64-apple-macos11   -o "$TMP_ARM" "$SRC" || exit 1
/usr/bin/xcrun swiftc -O -target x86_64-apple-macos11  -o "$TMP_X86" "$SRC" || exit 1

# Combine via lipo
/usr/bin/lipo -create -output "$OUT" "$TMP_ARM" "$TMP_X86" || exit 1
/bin/rm -f "$TMP_ARM" "$TMP_X86"

# Re-sign — lipo strips the per-arch ad-hoc signatures, so the resulting
# universal binary is unsigned. macOS Gatekeeper kills unsigned binaries
# instantly since Big Sur with "SIGKILL Code Signature Invalid". Ad-hoc signing ("-")
# matches the default swiftc binaries.
/usr/bin/codesign --force --sign - "$OUT" || exit 1

# Verify
/usr/bin/file "$OUT"
/usr/bin/codesign -dv "$OUT" 2>&1 | /usr/bin/head -3
