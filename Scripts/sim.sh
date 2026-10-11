#!/bin/bash
# The app's feedback loop in the iOS Simulator: build, install, run a session from a file, take a
# screenshot of the simulator's screen (only the simulator, never the desktop), and pull the
# app's diagnostics and transcripts back out.
#
#   Scripts/sim.sh build                       generate the Xcode project and build for the simulator
#   Scripts/sim.sh install                     boot the simulator and install the last build
#   Scripts/sim.sh models                      copy this Mac's downloaded models into the app (instant APFS clones)
#   Scripts/sim.sh run [launch args…]          relaunch the app; -replay/-audio-file paths are copied in first
#   Scripts/sim.sh wait [timeout]              wait until the running session ends (its diagnostics say "end")
#   Scripts/sim.sh shot NAME                   screenshot to .sim/shots/NAME.png
#   Scripts/sim.sh diag                        copy the newest diagnostics file out and summarise it
#   Scripts/sim.sh transcripts                 copy saved transcripts to .sim/transcripts
#   Scripts/sim.sh ui KEY VALUE                appearance light|dark, text <size>, contrast on|off
#   Scripts/sim.sh logs [minutes]              the app's unified log
#   Scripts/sim.sh stop                        terminate the app
#
# SIM_DEVICE picks the simulator by name (default: iPhone 17 Pro Max).
# See Sources/CaptionSession/LaunchOptions.swift for every launch argument.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE_NAME=${SIM_DEVICE:-iPhone 17 Pro Max}
BUNDLE=io.nlws.livecaption
OUT=.sim
DERIVED=$OUT/dd
APP=$DERIVED/Build/Products/Debug-iphonesimulator/OpenCaptions.app
MODELS="$HOME/Library/Application Support/FluidAudio/Models"

udid() {
  xcrun simctl list devices available -j |
    python3 -I -c 'import json,sys
name=sys.argv[1]
for rt,ds in json.load(sys.stdin)["devices"].items():
    if "iOS" in rt:
        for d in ds:
            if d["name"]==name: print(d["udid"]); sys.exit()
sys.exit("no simulator named " + name)' "$DEVICE_NAME"
}

boot() {
  local id; id=$(udid)
  xcrun simctl bootstatus "$id" -b >/dev/null
  echo "$id"
}

container() { xcrun simctl get_app_container "$(udid)" "$BUNDLE" data; }

cmd=${1:-}; shift || true
case "$cmd" in
  build)
    mkdir -p "$OUT"
    # The punctuation model is bundled from .models/punctuation; built once, not committed.
    Scripts/make-punctuation-model.sh
    (cd App && xcodegen generate --quiet)
    set +e
    xcodebuild -project App/OpenCaptions.xcodeproj -scheme OpenCaptions \
      -destination "id=$(udid)" \
      -derivedDataPath "$DERIVED" build > "$OUT/build.log" 2>&1
    status=$?
    set -e
    grep -E 'error:|warning: .*App/Sources' "$OUT/build.log" | sort -u | head -40 || true
    if [ $status -eq 0 ]; then echo "BUILD SUCCEEDED"; else echo "BUILD FAILED (full log: $OUT/build.log)"; exit 1; fi
    ;;
  install)
    id=$(boot)
    xcrun simctl install "$id" "$APP"
    echo "installed on $DEVICE_NAME ($id)"
    ;;
  models)
    dest="$(container)/Library/Application Support/FluidAudio/Models"
    mkdir -p "$dest"
    for m in nemotron-streaming sortformer parakeet-unified-en-0.6b; do
      [ -d "$MODELS/$m" ] || { echo "missing $MODELS/$m — run the harness once to download it"; continue; }
      rm -rf "${dest:?}/$m"
      cp -cR "$MODELS/$m" "$dest/$m"
      echo "seeded $m"
    done
    ;;
  run)
    id=$(boot)
    data=$(container)
    mkdir -p "$data/tmp/inputs"
    args=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -replay|-audio-file)
          src=$2; dst="$data/tmp/inputs/$(basename "$src")"
          cp "$src" "$dst"; args+=("$1" "$dst"); shift 2 ;;
        *) args+=("$1"); shift ;;
      esac
    done
    # `wait` only looks at diagnostics newer than this, so an earlier run's log is never mistaken
    # for this one's.
    mkdir -p "$OUT"; touch "$OUT/launched"
    xcrun simctl launch --terminate-running-process "$id" "$BUNDLE" ${args[@]+"${args[@]}"} >/dev/null
    echo "launched ${args[*]-}"
    ;;
  wait)
    timeout=${1:-120}
    dir="$(container)/Documents/Diagnostics"
    for _ in $(seq "$timeout"); do
      latest=$(find "$dir" -name '*.jsonl' -newer "$OUT/launched" 2>/dev/null | head -1 || true)
      if [ -n "$latest" ] && grep -q '"event":"end"' "$latest"; then echo "session ended"; exit 0; fi
      if [ -n "$latest" ] && grep -q '"event":"failed"' "$latest"; then echo "session FAILED"; tail -3 "$latest"; exit 1; fi
      sleep 1
    done
    echo "timed out after ${timeout}s"; exit 1
    ;;
  shot)
    mkdir -p "$OUT/shots"
    xcrun simctl io "$(udid)" screenshot "$OUT/shots/${1:?name}.png" >/dev/null 2>&1
    echo "$OUT/shots/$1.png"
    ;;
  diag)
    dir="$(container)/Documents/Diagnostics"
    latest=$(ls -t "$dir"/*.jsonl | head -1)
    mkdir -p "$OUT/diag"
    cp "$latest" "$OUT/diag/"
    python3 -I - "$latest" <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
status = [r for r in rows if r["event"] == "status"]
print(sys.argv[1].rsplit("/", 1)[-1])
for r in rows:
    if r["event"] != "status":
        print(f'  {r["t"]:8.2f}s {r["event"]} ' + " ".join(f"{k}={v}" for k, v in r.items() if k not in ("t", "event")))
if status:
    last = status[-1]
    print(f'  {len(status)} status lines; audio {last["audio"]:.1f}s, wall {last["wall"]:.1f}s, '
          f'rtf {last["rtf"]:.2f}, load {last["load"]:.2f}, slowest {last["slowest"]:.2f}s, '
          f'peak memory {max(r["memoryMB"] for r in status):.0f} MB, words {last["words"]}, '
          f'turns {last["turns"]}, speakers {last["speakers"]}, thermal {last["thermal"]}')
EOF
    ;;
  transcripts)
    mkdir -p "$OUT/transcripts"
    cp "$(container)/Library/Application Support/Transcripts/"*.json "$OUT/transcripts/" 2>/dev/null || true
    ls -t "$OUT/transcripts"
    ;;
  ui)
    id=$(udid)
    case "${1:?key}" in
      appearance) xcrun simctl ui "$id" appearance "${2:?light|dark}" ;;
      text) xcrun simctl ui "$id" content_size "${2:?size e.g. large, accessibility-extra-extra-extra-large}" ;;
      contrast) xcrun simctl ui "$id" increase_contrast "$([ "${2:-on}" = on ] && echo enabled || echo disabled)" ;;
      *) echo "unknown ui key $1"; exit 1 ;;
    esac
    ;;
  logs)
    xcrun simctl spawn "$(udid)" log show --style compact --last "${1:-5}m" \
      --predicate 'subsystem == "io.nlws.livecaption"'
    ;;
  stop)
    xcrun simctl terminate "$(udid)" "$BUNDLE" || true
    ;;
  *)
    sed -n '2,20p' "$0"; exit 1 ;;
esac
