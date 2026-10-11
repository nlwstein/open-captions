#!/bin/bash
# Builds an unsigned IPA of the app for sideloading, and checks what went into it.
#
#   Scripts/make-ipa.sh [VERSION [BUILD]]
#
# VERSION is the marketing version (default 0.1.0); BUILD is the build number (default: the commit
# count). Writes .ipa/OpenCaptions-VERSION.ipa and .ipa/OpenCaptions-VERSION.ipa.sha256.
#
# The IPA is not signed. AltStore, SideStore, Sideloadly or atvloadly sign it with the installer's
# own Apple ID when they put it on the phone. Run by .github/workflows/ci.yml and release.yml.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-0.1.0}
BUILD=${2:-$(git rev-list --count HEAD)}
OUT=.ipa
NAME=OpenCaptions-$VERSION.ipa
APP=$OUT/dd/Build/Products/Release-iphoneos/OpenCaptions.app

fail() { echo "make-ipa: $*" >&2; exit 1; }

mkdir -p "$OUT"
# The punctuation model is bundled from .models/punctuation; built once, not committed.
Scripts/make-punctuation-model.sh
(cd App && xcodegen generate --quiet)

echo "Building OpenCaptions $VERSION ($BUILD) for iOS devices…"
status=0
xcodebuild -project App/OpenCaptions.xcodeproj -scheme OpenCaptions \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$OUT/dd" \
  -skipMacroValidation -skipPackagePluginValidation \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > "$OUT/build.log" 2>&1 || status=$?
grep -E 'error:|warning: .*App/Sources' "$OUT/build.log" | sort -u | head -40 || true
[ $status -eq 0 ] || fail "build failed (full log: $OUT/build.log)"

# What a sideloaded copy needs, checked before it is packaged.
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Info.plist"; }
[ "$(plist CFBundleShortVersionString)" = "$VERSION" ] || fail "Info.plist version is $(plist CFBundleShortVersionString), not $VERSION"
[ "$(plist CFBundleVersion)" = "$BUILD" ] || fail "Info.plist build is $(plist CFBundleVersion), not $BUILD"
[ "$(plist CFBundleIdentifier)" = "io.nlws.livecaption" ] || fail "unexpected bundle id $(plist CFBundleIdentifier)"
[ -d "$APP/Punctuation.mlmodelc" ] || fail "Punctuation.mlmodelc is missing from the bundle"
[ -s "$APP/vocabulary.tsv" ] || fail "vocabulary.tsv is missing from the bundle"
binary="$APP/$(plist CFBundleExecutable)"
lipo -archs "$binary" | grep -qw arm64 || fail "$binary is not arm64 ($(lipo -archs "$binary"))"

rm -rf "$OUT/Payload" "$OUT/$NAME" "$OUT/$NAME.sha256"
mkdir "$OUT/Payload"
ditto "$APP" "$OUT/Payload/OpenCaptions.app"
(cd "$OUT" && zip -qry "$NAME" Payload && shasum -a 256 "$NAME" > "$NAME.sha256")
rm -rf "$OUT/Payload"

echo "$OUT/$NAME ($(du -h "$OUT/$NAME" | cut -f1 | tr -d ' '), version $VERSION, build $BUILD, $(lipo -archs "$binary"))"
cat "$OUT/$NAME.sha256"
