#!/usr/bin/env bash
set -euo pipefail

export MBGA_SIGN_IDENTITY="${MBGA_SIGN_IDENTITY:-Apple Development: Roman Potapov (LKU8Y4CMYF)}"
TEAM="${MBGA_TEAM:-9RMCLTA387}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/^set(MBGA_VERSION "\(.*\)")$/\1/p' CMakeLists.txt)"
PUBLIC_KEY="$(sed -n 's/^set(MBGA_UPDATE_PUBLIC_KEY "\(.*\)")$/\1/p' CMakeLists.txt)"
TAG="v$VERSION"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
AUTH=()
if [[ -n "${MBGA_ASC_KEY_PATH:-}" ]]; then
  AUTH=(-authenticationKeyPath "$MBGA_ASC_KEY_PATH" -authenticationKeyID "${MBGA_ASC_KEY_ID:?}"
    -authenticationKeyIssuerID "${MBGA_ASC_ISSUER_ID:?}")
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or set aside your changes first: a release is built from a commit." >&2
  exit 1
fi
git fetch -q origin
if [[ -z "$(git branch -r --contains HEAD)" ]]; then
  echo "Push $(git rev-parse --short HEAD) to GitHub first." >&2
  exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "$TAG is out already. Raise MBGA_VERSION in CMakeLists.txt." >&2
  exit 1
fi

KEY="${MBGA_UPDATE_KEY:-$(security find-generic-password -s "MBGA update signing key" -a mbga -w)}"
if [[ "$(MBGA_UPDATE_KEY="$KEY" swift scripts/update-signing.swift public-key)" != "$PUBLIC_KEY" ]]; then
  echo "The signing key doesn't match MBGA_UPDATE_PUBLIC_KEY: installed copies would refuse this update." >&2
  exit 1
fi

scripts/build.sh --release
OUT="$ROOT/build/release/assets"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "Sending ${TAG} to Apple to be notarized…"
ARCHIVE="$ROOT/build/release/MBGA.xcarchive"
rm -rf "$ARCHIVE"
mkdir -p "$ARCHIVE/Products/Applications"
ditto "$ROOT/build/release/out/MBGA.app" "$ARCHIVE/Products/Applications/MBGA.app"
python3 - "$ARCHIVE" "$OUT" "$VERSION" "$MBGA_SIGN_IDENTITY" "$TEAM" <<'PY'
import datetime, plistlib, sys
archive, out, version, identity, team = sys.argv[1:]
plistlib.dump({
    "ApplicationProperties": {
        "ApplicationPath": "Applications/MBGA.app", "Architectures": ["arm64"],
        "CFBundleIdentifier": "dev.mbga.browser", "CFBundleShortVersionString": version,
        "CFBundleVersion": version, "SigningIdentity": identity, "Team": team,
    },
    "ArchiveVersion": 2, "CreationDate": datetime.datetime.now(datetime.timezone.utc),
    "Name": "MBGA", "SchemeName": "MBGA",
}, open(f"{archive}/Info.plist", "wb"))
plistlib.dump({"method": "developer-id", "teamID": team, "signingStyle": "automatic", "destination": "upload"},
              open(f"{out}/ExportOptions.plist", "wb"))
PY
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} >"$OUT/upload.log" 2>&1 || {
  tail -20 "$OUT/upload.log" >&2
  exit 1
}
for _ in $(seq 120); do
  if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" \
    ${AUTH[@]+"${AUTH[@]}"} >"$OUT/notarized.log" 2>&1; then
    break
  fi
  if ! grep -q "not ready for distribution" "$OUT/notarized.log"; then
    tail -20 "$OUT/notarized.log" >&2
    exit 1
  fi
  sleep 30
done
APP="$OUT/notarized/MBGA.app"
if [[ ! -d "$APP" ]]; then
  echo "Apple hasn't notarized ${TAG} after an hour. Run the script again later." >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
xcrun stapler validate -q "$APP"
spctl --assess --type execute "$APP"

echo "Packing ${TAG}…"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$OUT/MBGA.zip"
mkdir "$OUT/dmg"
ditto "$APP" "$OUT/dmg/MBGA.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname MBGA -srcfolder "$OUT/dmg" -fs APFS -format ULFO "$OUT/MBGA.dmg"
rm -rf "$OUT/dmg"
SIGNED="$(MBGA_UPDATE_KEY="$KEY" swift scripts/update-signing.swift sign "$OUT/MBGA.zip")"
python3 - "$OUT" "$VERSION" "$REPO" "$TAG" "$SIGNED" <<'PY'
import json, os, sys
out, version, repo, tag, signed = sys.argv[1:]
sha256, signature = signed.split()
archive = os.path.join(out, "MBGA.zip")
json.dump({
    "version": version,
    "url": f"https://github.com/{repo}/releases/download/{tag}/MBGA.zip",
    "size": os.path.getsize(archive),
    "sha256": sha256,
    "signature": signature,
    "minimumSystemVersion": "15.0",
}, open(os.path.join(out, "update.json"), "w"), indent=2)
PY

PREVIOUS="$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || true)"
{
  echo "## What's new"
  echo
  git log --no-merges --format='- %s' ${PREVIOUS:+"$PREVIOUS..HEAD"} | grep -v "^- Call this version of MBGA" | head -50
  echo
  echo "## Install"
  echo
  echo "MBGA runs on macOS 15 or later on Apple silicon. Copy and paste into Terminal:"
  echo
  echo '```sh'
  echo "curl -fL https://github.com/$REPO/releases/latest/download/MBGA.zip -o /tmp/MBGA.zip && ditto -x -k /tmp/MBGA.zip /Applications && open /Applications/MBGA.app"
  echo '```'
  echo
  echo "Or download MBGA.dmg below, open it and drag MBGA to Applications."
  echo
  echo "Once installed, MBGA updates itself."
} >"$OUT/notes.md"

gh release create "$TAG" "$OUT/MBGA.dmg" "$OUT/MBGA.zip" "$OUT/update.json" \
  --target "$(git rev-parse HEAD)" --title "MBGA $VERSION" --notes-file "$OUT/notes.md"
git fetch -q --tags origin
echo "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"
