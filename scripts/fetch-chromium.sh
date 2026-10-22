#!/bin/bash
set -euo pipefail

POSITION=1689411
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/third_party/chromium"
DL="$ROOT/third_party/chromium-dl"
URL="https://storage.googleapis.com/chromium-browser-snapshots/Mac_Arm/$POSITION/chrome-mac.zip"

if [[ -d "$DEST/chrome-mac/Chromium.app" ]]; then
  echo "Chromium already in $DEST"
  exit 0
fi
mkdir -p "$DL"
echo "Downloading Chromium snapshot $POSITION"
curl -fSL --retry 3 -o "$DL/chrome-mac.zip" "$URL"
rm -rf "$DEST" && mkdir -p "$DEST"
ditto -x -k "$DL/chrome-mac.zip" "$DEST"
defaults read "$DEST/chrome-mac/Chromium.app/Contents/Info.plist" CFBundleShortVersionString
