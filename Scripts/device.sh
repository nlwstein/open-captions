#!/bin/bash
# Build the app for a real iPhone, install it, and launch it.
#
#   Scripts/device.sh build      generate the project and build signed for the device
#   Scripts/device.sh install    install the last build on the device
#   Scripts/device.sh run        build, install and launch
#   Scripts/device.sh teams      list the signing teams Xcode knows about
#
# Signing: automatic, with the team in LC_TEAM, or the only team Xcode is signed in to. A free
# personal team works: the app runs for seven days before it needs installing again, and the
# free team allows three such apps on a device at once.
#
# LC_DEVICE picks the device by name (default: the first paired iPhone).
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE=io.nlws.livecaption
OUT=.device
DERIVED=$OUT/dd
APP=$DERIVED/Build/Products/Debug-iphoneos/LiveCaption.app

teams() {
  defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null |
    grep -E 'teamID|teamName|isFreeProvisioningTeam' || true
}

team() {
  if [ -n "${LC_TEAM:-}" ]; then echo "$LC_TEAM"; return; fi
  local ids
  ids=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null |
    sed -n 's/.*teamID = \([A-Z0-9]*\);/\1/p' | sort -u)
  case $(printf '%s\n' "$ids" | grep -c .) in
    0) echo "no signing team: sign in under Xcode > Settings > Accounts" >&2; exit 1 ;;
    1) echo "$ids" ;;
    *) echo "several teams; set LC_TEAM to one of:" >&2; teams >&2; exit 1 ;;
  esac
}

device() {
  local list
  list=$OUT/devices.json
  mkdir -p "$OUT"
  xcrun devicectl list devices --json-output "$list" >/dev/null
  python3 -I -c 'import json,sys
want=sys.argv[2]
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    p=d.get("hardwareProperties",{}); n=d.get("deviceProperties",{}).get("name","")
    if p.get("platform")=="iOS" and p.get("reality")=="physical" and (not want or n==want):
        print(p["udid"]); sys.exit()
sys.exit("no paired iPhone" + (" named "+want if want else ""))' "$list" "${LC_DEVICE:-}"
}

cmd=${1:-}; shift || true
case "$cmd" in
  teams) teams ;;
  build)
    mkdir -p "$OUT"
    t=$(team)
    # Built for the device itself, not a generic one: that is what registers it with the team
    # and puts it in the provisioning profile.
    d=$(device)
    (cd App && xcodegen generate --quiet)
    set +e
    xcodebuild -project App/LiveCaption.xcodeproj -scheme LiveCaption \
      -destination "id=$d" -derivedDataPath "$DERIVED" \
      -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
      DEVELOPMENT_TEAM="$t" build > "$OUT/build.log" 2>&1
    status=$?
    set -e
    grep -E 'error:' "$OUT/build.log" | sort -u | head -40 || true
    if [ $status -eq 0 ]; then echo "BUILD SUCCEEDED (team $t)"; else echo "BUILD FAILED (full log: $OUT/build.log)"; exit 1; fi
    ;;
  install)
    xcrun devicectl device install app --device "$(device)" "$APP"
    ;;
  run)
    "$0" build
    id=$(device)
    xcrun devicectl device install app --device "$id" "$APP"
    xcrun devicectl device process launch --device "$id" "$BUNDLE"
    ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
