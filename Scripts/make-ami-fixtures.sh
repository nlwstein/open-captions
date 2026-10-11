#!/usr/bin/env bash
#
# Builds the real-speech fixtures from the AMI Meeting Corpus, plus a synthetic twin of
# the same conversation for the controlled comparison in docs/RESEARCH.md.
#
#   Scripts/make-ami-fixtures.sh              # into Fixtures/
#   Scripts/make-ami-fixtures.sh --corpus DIR # use a corpus that is already downloaded
#
# Three fixtures come out of one 46-second window of ES2002a — the kick-off meeting where
# four participants introduce themselves:
#
#   ami-meeting       ES2002a.Mix-Headset.wav  close headset mics, real room, real voices
#   ami-meeting-far   ES2002a.Array1-01.wav    one tabletop array mic, the far-field case
#   ami-meeting-synth the same words, same four turn-takers, re-synthesised by `say`
#
# The point of building all three from one window is that the reference transcript is
# identical for all three. Any difference in score is the channel, not the words.
#
# The corpus is CC BY 4.0. See Fixtures/README.md for the required attribution.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="${REPO}/.corpora/ami"
OUT="${REPO}/Fixtures"
WORK="${REPO}/.fixture-build/ami"

CORPUS_BASE="https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus"
ANNOTATIONS_URL="https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip"

MEETING="ES2002a"

# The window, in corpus time. Both edges sit in a silence: speech runs 55.98 - 101.76 and
# the nearest gaps either side are wide, so no clip cuts a word in half.
CLIP_START=55.60
CLIP_END=102.30
REF_START=55.98
REF_END=101.76

# Conversational rate for the twin. The real participants run 135-190 wpm across these
# turns; one fixed rate keeps the twin's difficulty a property of the voices rather than
# of a per-turn speed the real recording never had.
TTS_RATE=175

# One voice per participant. Three of the four real speakers are male and one female, and
# the accents are mixed, so the twin is too. These are the natural-sounding voices macOS
# ships with rather than the novelty ones — an obviously robotic twin would make the
# synthetic case harder for reasons that have nothing to do with the hypothesis.
voice_for() {
  case "$1" in
    A) echo "Daniel" ;;   # en_GB male
    B) echo "Samantha" ;; # en_US female
    C) echo "Reed" ;;     # en_US male
    D) echo "Rishi" ;;    # en_IN male
    *) echo "Samantha" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --corpus) CORPUS="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

for tool in ffmpeg ffprobe python3 say; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

# ---------------------------------------------------------------------------------------
# Corpus
# ---------------------------------------------------------------------------------------

fetch() {
  local url="$1" dest="$2"
  if [[ -s "$dest" ]]; then
    echo "  have $(basename "$dest")"
    return
  fi
  echo "  fetching $(basename "$dest")"
  curl -fsSL --retry 3 -o "$dest.part" "$url"
  mv "$dest.part" "$dest"
}

mkdir -p "$CORPUS"
echo "Corpus: $CORPUS"
fetch "$CORPUS_BASE/${MEETING}/audio/${MEETING}.Mix-Headset.wav" "$CORPUS/${MEETING}.Mix-Headset.wav"
fetch "$CORPUS_BASE/${MEETING}/audio/${MEETING}.Array1-01.wav" "$CORPUS/${MEETING}.Array1-01.wav"

if [[ ! -d "$CORPUS/words" ]]; then
  fetch "$ANNOTATIONS_URL" "$CORPUS/ami_public_manual_1.6.2.zip"
  echo "  extracting annotations"
  # The archive has no wrapper directory: it drops words/, segments/ and the rest straight
  # into the target. Extracted in place, so the zip and the audio stay together.
  unzip -qo "$CORPUS/ami_public_manual_1.6.2.zip" -d "$CORPUS"
fi

# ---------------------------------------------------------------------------------------
# Reference and metadata
# ---------------------------------------------------------------------------------------

mkdir -p "$WORK" "$OUT/audio" "$OUT/reference" "$OUT/metadata"

echo "Reference for ${MEETING} ${REF_START}-${REF_END}s"
python3 -I "${REPO}/Scripts/ami_annotations.py" reference \
  "$CORPUS" "$MEETING" "$REF_START" "$REF_END" > "$WORK/reference.txt"
python3 -I "${REPO}/Scripts/ami_annotations.py" turns \
  "$CORPUS" "$MEETING" "$REF_START" "$REF_END" > "$WORK/turns.txt" 2>"$WORK/turns.stats"

echo "  $(cat "$WORK/turns.stats")"
echo "  $(wc -l < "$WORK/reference.txt" | tr -d ' ') lines"

# The same reference for all three fixtures: that identity is the whole point of the
# comparison, so it is written from the one file rather than typed three times.
for name in ami-meeting ami-meeting-far ami-meeting-synth; do
  cp "$WORK/reference.txt" "$OUT/reference/${name}.txt"
done

metadata() {
  local name="$1" scene="$2" noise="$3" notes="$4"
  cat > "$OUT/metadata/${name}.json" <<JSON
{
  "title": "AMI ${MEETING} — introductions",
  "scene": "${scene}",
  "speakerCount": 4,
  "noise": "${noise}",
  "knownNames": ["laura", "david", "andrew", "craig"],
  "notes": "${notes}"
}
JSON
}

metadata ami-meeting \
  "four-person meeting, headset microphones, real meeting room" \
  "real room, occasional crosstalk" \
  "AMI Meeting Corpus ES2002a, ${CLIP_START}-${CLIP_END}s. CC BY 4.0. Mix of all four headset mics."
metadata ami-meeting-far \
  "same meeting, one tabletop array microphone" \
  "real room, far-field, reverberant" \
  "AMI Meeting Corpus ES2002a, Array1-01, ${CLIP_START}-${CLIP_END}s. CC BY 4.0. Same words as ami-meeting."
metadata ami-meeting-synth \
  "synthesised twin of ami-meeting: same words, same four turn-takers" \
  "none (synthesized)" \
  "Generated by Scripts/make-ami-fixtures.sh from the ami-meeting reference. One \`say\` voice per participant, no room, no overlap."

# ---------------------------------------------------------------------------------------
# Audio
# ---------------------------------------------------------------------------------------

# The corpus recordings are mastered *far* below the synthetic fixtures — ami-meeting sits at
# -39.7 LUFS against roughly -19 for the `say` renders, 21 dB down, and the array microphone is
# 28 dB down. Left alone that is a confound, not a property of real speech: at matched level the
# same close-mic window scores 16.0% WER against 24.4%, and its critical-information score goes
# from 51.9% to 96.3%. So every clip this script emits is peak-normalised into the band the rest
# of the library already occupies, and the raw level is reported rather than committed.
#
# Peak, not loudness: a limiter would be needed to reach the synthetic fixtures' LUFS without
# clipping, and a limiter is processing the recogniser would otherwise never see.
TARGET_PEAK=-1.5

echo "Cutting real audio"

# Whole seconds, via parameter expansion rather than the `cut` command: a function named
# `cut` shadows /usr/bin/cut for the whole script, and the two calling each other is a fork
# bomb, not an error message.
duration_of() {
  local seconds
  seconds="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1")"
  printf '%s\n' "${seconds%%.*}"
}

peak_of() {
  ffmpeg -v info -i "$1" -af volumedetect -f null - 2>&1 \
    | sed -n 's/.*max_volume: \(-*[0-9.]*\) dB.*/\1/p'
}

# Applies the static gain that puts a clip's sample peak on TARGET_PEAK. Static gain only —
# no compression, no limiting — so the fixture differs from the corpus by one number.
peak_normalise() {
  local src="$1" dest="$2"
  local peak gain
  peak="$(peak_of "$src")"
  gain="$(python3 -I -c "print(f'{${TARGET_PEAK} - (${peak}):.2f}')")"
  ffmpeg -v error -y -i "$src" -af "volume=${gain}dB" \
    -ar 16000 -ac 1 -c:a pcm_s16le "$dest"
  printf "  %-24s %ss  peak %s -> %s dBFS (gain %+0.2f dB)\n" \
    "$(basename "$dest")" "$(duration_of "$dest")" "$peak" "$(peak_of "$dest")" "$gain"
}

trim_clip() {
  local src="$1" dest="$2"
  # atrim inside the filter graph, not -ss/-t on the output: an output seek still lets the
  # filter graph read the whole file, which silently produces the wrong segment.
  ffmpeg -v error -y -i "$src" \
    -af "atrim=start=${CLIP_START}:end=${CLIP_END},asetpts=PTS-STARTPTS" \
    -ar 16000 -ac 1 -c:a pcm_s16le "$dest"
}

trim_clip "$CORPUS/${MEETING}.Mix-Headset.wav" "$WORK/ami-meeting.raw.wav"
trim_clip "$CORPUS/${MEETING}.Array1-01.wav" "$WORK/ami-meeting-far.raw.wav"
peak_normalise "$WORK/ami-meeting.raw.wav" "$OUT/audio/ami-meeting.wav"
peak_normalise "$WORK/ami-meeting-far.raw.wav" "$OUT/audio/ami-meeting-far.wav"

echo "Synthesising the twin"
rm -f "$WORK"/turn_*.caf
total="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/audio/ami-meeting.wav")"

# Each turn is rendered by its own voice and then delayed to the offset it occupied in the
# real recording, so the twin reproduces the turn-taking as well as the words.
index=0
delays=()
inputs=()
while IFS='|' read -r start end speaker text; do
  [[ -z "${text// }" ]] && continue
  caf="$WORK/turn_$(printf '%03d' "$index").caf"
  say -v "$(voice_for "$speaker")" -r "$TTS_RATE" -o "$caf" --data-format=LEF32@16000 "$text"
  offset="$(python3 -I -c "print(f'{(${start} - ${CLIP_START}) * 1000:.0f}')")"
  inputs+=(-i "$caf")
  # 6 dB of headroom per voice before summing: `say` renders near full scale, and two turns
  # that overlap in the original would otherwise clip where they meet. peak_normalise puts
  # the level back afterwards.
  delays+=("[${index}:a]adelay=${offset}:all=1,volume=-6dB[t${index}]")
  index=$((index + 1))
done < <(grep -v '^#' "$WORK/turns.txt")

filter="$(printf '%s;' "${delays[@]}")"
filter+="$(for i in $(seq 0 $((index - 1))); do printf '[t%s]' "$i"; done)"
filter+="amix=inputs=${index}:normalize=0:duration=longest[mixed];"
filter+="[mixed]apad,atrim=0:${total},asetpts=PTS-STARTPTS[out]"

ffmpeg -v error -y "${inputs[@]}" \
  -filter_complex "$filter" -map "[out]" \
  -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/ami-meeting-synth.raw.wav"

peak_normalise "$WORK/ami-meeting-synth.raw.wav" "$OUT/audio/ami-meeting-synth.wav"

echo
echo "Done. $(ls "$OUT/audio" | wc -l | tr -d ' ') fixtures in $OUT/audio"
