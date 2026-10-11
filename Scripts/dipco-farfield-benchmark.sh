#!/usr/bin/env bash
#
# Scores a diarizer across the DiPCo dinner-party sessions, far-field, against the corpus's own
# speaker transcriptions.
#
#   Scripts/dipco-farfield-benchmark.sh S02 S03 S04 [--device U01] [--channel CH1] [--variant dihard3]
#
# DiPCo is ten sessions of four people around a dining table — a simulated dinner party recorded in
# a lab for Interspeech 2020, with music piped into several sessions and real overlapping speech.
# It is the closest public audio to what this app is for, which is why it is here next to the AMI
# meetings in docs/ENGINES.md.
#
# Each session has up to five far-field array devices (U01-U05) of seven channels each, plus one
# close-talk headset per participant. The transcriptions carry a *separate* timestamp set per
# device, so the same conversation is scored against whichever microphone this script selects, and
# the difference between two runs is the room rather than the words.
#
# The corpus is not fetched here: it is 12.5 GB and belongs to a deliberate choice, not to a
# script run. Fetch it with
#
#   hf download huckiyang/DiPCo --repo-type dataset --local-dir .corpora/dipco
#
# The set of devices is not uniform across sessions, and there is no default that works for all
# ten: five sessions ship U01-U03 at seven channels apiece (S01, S02, S04, S07, S08) and the other
# five ship U04-U05 complete instead (S03, S05, S06, S09, S10). No session has both families, and
# the few stray U01/U02/U03 channels elsewhere are single channels rather than arrays. So the device
# is an argument rather than a default, and the script names what is actually present when the one
# asked for is missing rather than scoring silence.
#
# The transcriptions themselves carry all five devices for all ten sessions, so which audio a
# session ships is a packaging quirk and not a limit on what can be scored. Measured cost of the
# choice: S02 scores 46/48/50% on U01/U02/U03 and S03 scores 34/36% on U04/U05.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="${REPO}/.corpora/dipco"
WORK="${REPO}/.fixture-build/dipco"
CLI="${FLUIDAUDIO_CLI:-/tmp/fluidaudio-eval/src/.build/release/fluidaudiocli}"
VARIANT="dihard3"
DEVICE="U01"
CHANNEL="CH1"

SESSIONS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --cli) CLI="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) SESSIONS+=("$1"); shift ;;
  esac
done

[[ ${#SESSIONS[@]} -gt 0 ]] || { echo "Name at least one session, e.g. S02" >&2; exit 2; }
[[ -d "$CORPUS" ]] || { echo "No corpus at $CORPUS. See the header for the fetch command." >&2; exit 1; }
[[ -x "$CLI" ]] || { echo "No diarizer CLI at $CLI. Pass --cli or set FLUIDAUDIO_CLI." >&2; exit 1; }

mkdir -p "$WORK"

# Sessions are split dev/eval in the corpus and the tuning set is not what a benchmark wants, but
# both are real and the split is not worth encoding as a default. Find whichever has it.
transcriptions_for() {
  local session="$1"
  for split in dev eval; do
    local candidate="${CORPUS}/transcriptions/${split}/${session}.json"
    [[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

audio_for() {
  local session="$1" name="$2"
  for split in dev eval; do
    local candidate="${CORPUS}/audio/${split}/${name}"
    [[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

for session in "${SESSIONS[@]}"; do
  echo "=== ${session} / ${DEVICE}.${CHANNEL} (variant ${VARIANT}) ==="

  if ! json="$(transcriptions_for "$session")"; then
    echo "  no transcriptions for ${session} — skipping" >&2
    continue
  fi

  if ! audio="$(audio_for "$session" "${session}_${DEVICE}.${CHANNEL}.wav")"; then
    echo "  no ${session}_${DEVICE}.${CHANNEL}.wav. Arrays present for ${session}:" >&2
    for device in U01 U02 U03 U04 U05; do
      channels=$(for split in dev eval; do
        ls "${CORPUS}/audio/${split}/${session}_${device}."*.wav 2>/dev/null
      done | sed 's/.*\.//; s/\.wav//' | sort -u | tr '\n' ' ')
      [[ -n "$channels" ]] && echo "    ${device}: ${channels}" >&2
    done
    continue
  fi

  turns="${WORK}/${session}.turns.txt"
  python3 -I "${REPO}/Scripts/dipco_annotations.py" turns \
    "$json" "$DEVICE" > "$turns"
  echo "  $(wc -l < "$turns" | tr -d ' ') turns, $(python3 -I -c "
import collections, sys
rows = [l.split('|') for l in open('$turns')]
print(len({r[2] for r in rows}), 'speakers')")"

  log="${WORK}/${session}-${DEVICE}-${CHANNEL}-${VARIANT}.log"
  start=$(date +%s)
  "$CLI" lseend "$audio" --variant "$VARIANT" > "$log" 2>&1
  elapsed=$(( $(date +%s) - start ))

  python3 -I "${REPO}/Scripts/diarization_score.py" "$session" "$log" \
    --turns "$turns" --clip-start 0
  echo "  diarized in ${elapsed}s"
  echo
done
