#!/bin/zsh
# Builds a Developer ID signed, notarized and stapled Varmepumpe.app and zips it.
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
# Output: build/release/Varmepumpe-<version>.zip and its .sha256.
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
  OTHER_CODE_SIGN_FLAGS="$sign_flags" \
  build -quiet

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^Authority=Developer|TeamIdentifier=|Timestamp=|Runtime"
codesign -dvv "$APP/Contents/Helpers/varmepumpe-mcp" 2>&1 | grep -E "^Authority=Developer|Timestamp=|Runtime"
lipo -archs "$APP/Contents/MacOS/Varmepumpe"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ -z ${SKIP_NOTARIZE:-} ]]; then
  echo "==> Notarizing"
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
  xcrun notarytool submit "$ZIP" "${auth[@]}" --wait --timeout 30m --output-format json > "$OUT/notary.json"
  cat "$OUT/notary.json"
  status=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$OUT/notary.json")
  if [[ $status != Accepted ]]; then
    id=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$OUT/notary.json")
    xcrun notarytool log "$id" "${auth[@]}" || true
    echo "Notarization failed: $status" >&2
    exit 1
  fi
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  rm "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

(cd "$OUT" && shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256")
echo "==> Done: $ZIP"
