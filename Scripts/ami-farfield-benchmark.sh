#!/usr/bin/env bash
#
# Scores a diarizer over whole AMI meetings, far-field channel, against the corpus's own speaker
# annotations.
#
#   Scripts/ami-farfield-benchmark.sh EN2001a TS3003a [--variant dihard3] [--cli PATH]
#
# Why whole meetings rather than the 47-second fixtures the rest of the repo uses. The fixtures
# exist to hold the *words* constant while a channel or an engine changes, and for that a short
# window is right. This asks a different question — how a diarizer behaves across a real meeting —
# and there the window is the wrong instrument twice over: picking it is a judgement call that can
# flatter or penalise whichever model is being measured, and thirteen turns cannot support a
# percentage. A full meeting supplies thousands of turns and no window choice at all.
#
# The turn-length breakdown this prints is not decoration. Roughly half the turns in a real meeting
# are shorter than the diarizer's own 500 ms step, so they cannot be resolved by construction and
# they drag any flat average down. Splitting by length is what separates a model that is wrong from
# a question that was unanswerable.
#
# Requires the corpus at .corpora/ami. `make-ami-fixtures.sh` fetches the annotations this reads;
# the audio for a new meeting is fetched here, one channel per meeting.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="${REPO}/.corpora/ami"
WORK="${REPO}/.fixture-build/farfield"
BASE="https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus"
CLI="${FLUIDAUDIO_CLI:-/tmp/fluidaudio-eval/src/.build/release/fluidaudiocli}"
VARIANT="dihard3"

MEETINGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) VARIANT="$2"; shift 2 ;;
    --cli) CLI="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) MEETINGS+=("$1"); shift ;;
  esac
done

[[ ${#MEETINGS[@]} -gt 0 ]] || { echo "Name at least one meeting, e.g. EN2001a" >&2; exit 2; }
[[ -x "$CLI" ]] || { echo "No diarizer CLI at $CLI. Pass --cli or set FLUIDAUDIO_CLI." >&2; exit 1; }

mkdir -p "$WORK" "$CORPUS"

for meeting in "${MEETINGS[@]}"; do
  echo "=== ${meeting} (variant ${VARIANT}) ==="

  audio="${CORPUS}/${meeting}.Array1-01.wav"
  if [[ ! -s "$audio" ]]; then
    echo "  fetching ${meeting}.Array1-01.wav"
    curl -fsSL --retry 5 --retry-all-errors -o "${audio}.part" \
      "${BASE}/${meeting}/audio/${meeting}.Array1-01.wav"
    mv "${audio}.part" "$audio"
  fi

  # `turns` takes a corpus-time range. The whole meeting, so the range is 0 to its duration.
  duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$audio")"
  turns="${WORK}/${meeting}.turns.txt"
  python3 -I "${REPO}/Scripts/ami_annotations.py" turns \
    "$CORPUS" "$meeting" 0 "${duration%%.*}" > "$turns" 2>"${WORK}/${meeting}.stats"
  echo "  $(cat "${WORK}/${meeting}.stats")"

  log="${WORK}/${meeting}-${VARIANT}.log"
  start=$(date +%s)
  "$CLI" lseend "$audio" --variant "$VARIANT" > "$log" 2>&1
  elapsed=$(( $(date +%s) - start ))

  python3 -I "${REPO}/Scripts/diarization_score.py" "$meeting" "$log" \
    --turns "$turns" --clip-start 0
  echo "  diarized in ${elapsed}s"
  echo
done
