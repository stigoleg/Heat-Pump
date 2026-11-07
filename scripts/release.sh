#!/bin/zsh
# Builds Husly: a Developer ID signed, notarized and stapled Varmepumpe.app and packs it twice: a disk
# image for people to download, and a zip for the in-app updater (it only reads .zip assets, so
# installed versions keep updating).
#
# Usage: scripts/release.sh <version>
#
# Environment:
#   SIGN_IDENTITY        codesign identity (default "Developer ID Application")
#   SIGN_KEYCHAIN        keychain holding the identity (optional, CI)
#   BUILD_NUMBER         CFBundleVersion (default: number of commits)
#   Notarization, one of:
#     NOTARY_PROFILE                 keychain profile from `xcrun notarytool store-credentials`
#     NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID   App Store Connect API key
#     NOTARY_APPLE_ID, NOTARY_PASSWORD, NOTARY_TEAM_ID   Apple ID + app-specific password
#   SKIP_NOTARIZE=1      sign only (local smoke test; the result will not pass Gatekeeper)
#
# Output: build/release/Husly-<version>.dmg and Varmepumpe-<version>.zip, each with a .sha256.
# The zip holds Varmepumpe.app (the name installed versions' updater looks for); the disk image
# holds the same signed bundle named Husly.app. The updater swaps whatever path the app runs from.
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version>}
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3" >&2; exit 1; }

ROOT=${0:A:h:h}
cd "$ROOT"
SIGN_IDENTITY=${SIGN_IDENTITY:-"Developer ID Application"}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
DERIVED=build/release/DerivedData
APP=$DERIVED/Build/Products/Release/Varmepumpe.app
OUT=build/release
ZIP=$OUT/Varmepumpe-$VERSION.zip
# The download carries the app's name; the zip keeps the old one, which installed versions look for.
DMG=$OUT/Husly-$VERSION.dmg

sign_flags="--timestamp"
[[ -n ${SIGN_KEYCHAIN:-} ]] && sign_flags="$sign_flags --keychain $SIGN_KEYCHAIN"

echo "==> Building Varmepumpe $VERSION ($BUILD_NUMBER)"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodegen generate
xcodebuild -scheme Varmepumpe -configuration Release -derivedDataPath "$DERIVED" \
  -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM=49P95434EE \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="$sign_flags" \
  build -quiet

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^Authority=Developer|TeamIdentifier=|Timestamp=|Runtime"
codesign -dvv "$APP/Contents/Helpers/varmepumpe-mcp" 2>&1 | grep -E "^Authority=Developer|Timestamp=|Runtime"
lipo -archs "$APP/Contents/MacOS/Varmepumpe"
# Notarization rejects the debugging entitlement.
for bin in "$APP" "$APP/Contents/Helpers/varmepumpe-mcp"; do
  if codesign -d --entitlements - "$bin" 2>/dev/null | grep -q get-task-allow; then
    echo "$bin has com.apple.security.get-task-allow" >&2; exit 1
  fi
done

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

notary_auth() {
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    auth=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n ${NOTARY_KEY_PATH:-} ]]; then
    auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  elif [[ -n ${NOTARY_APPLE_ID:-} ]]; then
    auth=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
  else
    echo "No notarization credentials (NOTARY_PROFILE, NOTARY_KEY_* or NOTARY_APPLE_ID)." >&2
    exit 1
  fi
}

# Submits a file and waits; fails with the notary log unless Apple accepts it.
notarize() {
  local file=$1 json=$OUT/notary-${1:t:e}.json result id
  xcrun notarytool submit "$file" "${auth[@]}" --wait --timeout 30m --output-format json > "$json"
  cat "$json"
  result=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$json")
  if [[ $result != Accepted ]]; then
    id=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$json")
    xcrun notarytool log "$id" "${auth[@]}" || true
    echo "Notarization of ${file:t} failed: $result" >&2
    exit 1
  fi
}

if [[ -z ${SKIP_NOTARIZE:-} ]]; then
  echo "==> Notarizing the app"
  notary_auth
  notarize "$ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  rm "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

# The stapled app and a link to Applications, so it installs by dragging.
echo "==> Building the disk image"
stage=$OUT/dmg-root
rm -rf "$stage"
mkdir -p "$stage"
ditto "$APP" "$stage/Husly.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Husly -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" -quiet
rm -rf "$stage"
dmg_flags=(--sign "$SIGN_IDENTITY" --timestamp)
[[ -n ${SIGN_KEYCHAIN:-} ]] && dmg_flags+=(--keychain "$SIGN_KEYCHAIN")
codesign "${dmg_flags[@]}" "$DMG"
codesign --verify --verbose=2 "$DMG"

if [[ -z ${SKIP_NOTARIZE:-} ]]; then
  echo "==> Notarizing the disk image"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

(cd "$OUT" && shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
echo "==> Done: $DMG and $ZIP"
