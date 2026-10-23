#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PART="${1:-patch}"
LATEST="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1)"
IFS=. read -r MAJOR MINOR PATCH <<<"${LATEST#v}"
MAJOR="${MAJOR:-0}" MINOR="${MINOR:-0}" PATCH="${PATCH:-0}"
case "$PART" in
  patch) PATCH=$((PATCH + 1)) ;;
  minor) MINOR=$((MINOR + 1)) PATCH=0 ;;
  major) MAJOR=$((MAJOR + 1)) MINOR=0 PATCH=0 ;;
  *)
    echo "usage: $0 [patch|minor|major]" >&2
    exit 2
    ;;
esac
VERSION="$MAJOR.$MINOR.$PATCH"

sed -i '' "s/^set(MBGA_VERSION \".*\")$/set(MBGA_VERSION \"$VERSION\")/" CMakeLists.txt
echo "$VERSION"
