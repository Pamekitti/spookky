#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
test -d "$DEVELOPER_DIR" || { echo "Full Xcode is required." >&2; exit 1; }
test -d .cache/dependencies/ghostty/macos/GhosttyKit.xcframework || { echo "Build the pinned Ghostty dependency first." >&2; exit 1; }
xcodebuild -project Spookky.xcodeproj -scheme 'Spookky' -configuration "${1:-Debug}" -derivedDataPath DerivedData build
