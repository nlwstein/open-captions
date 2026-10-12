#!/bin/bash
# Builds a signed App Store build of the app and uploads it to App Store Connect, where it appears
# in TestFlight after Apple's processing (usually 5 to 30 minutes).
#
#   Scripts/upload-testflight.sh VERSION BUILD
#
# Needs an App Store Connect API key (a Team key with the Admin role, so Xcode may create the
# distribution certificate and profile itself) and the team it belongs to:
#
#   ASC_KEY_ID      the key's ID, e.g. 2X9R4HXF34
#   ASC_ISSUER_ID   the issuer ID shown above the list of keys
#   ASC_KEY_PATH    path to the downloaded AuthKey_<ID>.p8
#   APPLE_TEAM_ID   the ten-character team ID (developer.apple.com/account, Membership details)
#
# Signing is Xcode's cloud-managed signing: no certificates or profiles are stored anywhere, here
# or in CI. The app record (bundle ID io.nlws.livecaption) must already exist in App Store Connect.
# Run by .github/workflows/testflight.yml; works the same on a Mac with the key on disk.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: upload-testflight.sh VERSION BUILD}
BUILD=${2:?usage: upload-testflight.sh VERSION BUILD}
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH}" "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"
[ -s "$ASC_KEY_PATH" ] || { echo "upload-testflight: no key at $ASC_KEY_PATH" >&2; exit 1; }

OUT=.testflight
ARCHIVE=$OUT/OpenCaptions.xcarchive
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$(cd "$(dirname "$ASC_KEY_PATH")" && pwd)/$(basename "$ASC_KEY_PATH")"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

fail() { echo "upload-testflight: $*" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
Scripts/make-punctuation-model.sh
(cd App && xcodegen generate --quiet)

echo "Archiving OpenCaptions $VERSION ($BUILD) for team ${APPLE_TEAM_ID}…"
status=0
xcodebuild -project App/OpenCaptions.xcodeproj -scheme OpenCaptions \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$OUT/dd" -archivePath "$ARCHIVE" \
  -skipMacroValidation -skipPackagePluginValidation \
  "${AUTH[@]}" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  archive > "$OUT/archive.log" 2>&1 || status=$?
grep -E 'error:' "$OUT/archive.log" | sort -u | head -40 || true
[ $status -eq 0 ] || fail "archive failed (full log: $OUT/archive.log)"

APP=$ARCHIVE/Products/Applications/OpenCaptions.app
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Info.plist"; }
[ "$(plist CFBundleShortVersionString)" = "$VERSION" ] || fail "archived version is $(plist CFBundleShortVersionString), not $VERSION"
[ "$(plist CFBundleVersion)" = "$BUILD" ] || fail "archived build is $(plist CFBundleVersion), not $BUILD"
[ -d "$APP/Punctuation.mlmodelc" ] || fail "Punctuation.mlmodelc is missing from the archive"
[ -f "$APP/PrivacyInfo.xcprivacy" ] || fail "PrivacyInfo.xcprivacy is missing from the archive"

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

# Export a signed IPA, then upload it with altool. Letting xcodebuild upload (destination=upload)
# fails with an API key: its store-configuration request gets "Cannot verify client's JWT headers"
# (CDWebService 3004), though the same key signs the archive and altool accepts it.
echo "Exporting the signed IPA…"
status=0
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" \
  "${AUTH[@]}" > "$OUT/export.log" 2>&1 || status=$?
grep -E 'error:|EXPORT SUCCEEDED' "$OUT/export.log" | sort -u | head -40 || true
[ $status -eq 0 ] || fail "export failed (full log: $OUT/export.log)"
IPA=$(ls "$OUT"/export/*.ipa 2>/dev/null | head -1)
[ -n "$IPA" ] || fail "export made no .ipa (full log: $OUT/export.log)"

# altool looks for the key as AuthKey_<ID>.p8 in API_PRIVATE_KEYS_DIR, so give it a directory
# holding only that, and remove it afterwards.
KEYS=$(mktemp -d)
trap 'rm -rf "$KEYS"' EXIT
cp "$ASC_KEY_PATH" "$KEYS/AuthKey_$ASC_KEY_ID.p8"
chmod 600 "$KEYS/AuthKey_$ASC_KEY_ID.p8"

echo "Uploading to App Store Connect…"
status=0
API_PRIVATE_KEYS_DIR=$KEYS xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" > "$OUT/upload.log" 2>&1 || status=$?
grep -iE 'error|UPLOAD SUCCEEDED|No errors uploading' "$OUT/upload.log" | sort -u | head -40 || true
[ $status -eq 0 ] || fail "upload failed (full log: $OUT/upload.log)"
echo "Uploaded OpenCaptions $VERSION ($BUILD). It shows in TestFlight once Apple has processed it."
