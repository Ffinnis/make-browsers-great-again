#!/usr/bin/env bash
set -euo pipefail

CEF_VERSION="154.0.34+g14c5a08+chromium-154.0.8037.98"
PLATFORM="macosarm64"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/third_party/cef"
STAMP="$DEST/dist/.version"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$CEF_VERSION" ]]; then
  exit 0
fi

NAME="cef_binary_${CEF_VERSION}_${PLATFORM}_minimal"
URL="https://cef-builds.spotifycdn.com/$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$NAME.tar.bz2")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading CEF ${CEF_VERSION}…"
curl -fL --progress-bar -o "$WORK/cef.tar.bz2" "$URL"
EXPECTED="$(curl -fsSL "$URL.sha1")"
ACTUAL="$(shasum -a 1 "$WORK/cef.tar.bz2" | cut -d' ' -f1)"
if [[ "$EXPECTED" != "$ACTUAL" ]]; then
  echo "Checksum mismatch: expected $EXPECTED, got $ACTUAL" >&2
  exit 1
fi

tar -xjf "$WORK/cef.tar.bz2" -C "$WORK"
rm -rf "$DEST/dist"
mkdir -p "$DEST"
mv "$WORK/$NAME" "$DEST/dist"
echo "$CEF_VERSION" >"$STAMP"
